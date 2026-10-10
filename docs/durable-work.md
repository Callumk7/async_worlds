# Durable resolution and Discord outbox (ENG-7)

## Install and operate

Run `mix deps.get` and `mix ecto.migrate` before starting the upgraded application.
Oban 2.24 runs under the application supervisor with PostgreSQL-backed queues:
`resolution` (2 concurrent workers) and `discord_delivery` (2). Completed jobs are
pruned after seven days; snapshots/drafts and delivery records are not pruned.
The lifeline rescues jobs left executing after a crash after five minutes. Pending,
scheduled and retryable jobs survive application restarts. Run one bot instance.

Tests configure Oban's manual mode: queues/plugins do not run in the background,
and the fake Discord adapter is used. Tests explicitly perform/drain jobs and use
supervised helpers for worker infrastructure. No normal test contacts Discord.

## Resolution

Closing creates the immutable input snapshot, locks clocks, changes the tick to
resolving, and inserts a ResolveTick job in one database transaction. Repeated
close requests return the original snapshot without adding another job. Workers
resolve that snapshot, not live clocks. They append the initial draft using the
existing revision checks; duplicate workers finish successfully if another worker
already wrote it. They never replace a reviewed/edited or published draft.

Transient failures retry up to ten times. Invalid input/schema, missing records and
stale input cancel safely. Invalid snapshots leave the tick resolving and clock
management locked; do not unlock or edit immutable inputs to hide a failed job.
`Ticks.resolution_jobs(campaign_id, tick_id)` returns owning-tick Oban records for
DM-only diagnostics (state, attempts, sanitized errors). Authorized operator tools
may use Oban.retry_job(job.id) for a diagnosed transient failure. A stale job remains
safe because the worker checks both the input revision and lifecycle state.
Ticks closed before this migration have no queued job; an authorized local operator
can enqueue ResolveTick with the existing campaign_id, tick_id and snapshot revision
without reopening or refreezing the tick. Command/UI controls ship in later tickets.

## Enqueueing outbound content

`Deliveries.enqueue(campaign_id, tick_id, attrs)` is a trusted application API.
Use it **inside** the publication transaction (or a tick-open transaction) with:

```elixir
%{
  key: "tick:3:public-news:0",
  kind: :public,
  recipient_id: "345678901234567890",
  content: "Approved, player-safe world news"
}
```

Private records use kind `:private` and a Discord user ID; the adapter opens a DM
channel before sending. Recipients and content are fixed in the record; later
campaign setup changes do not silently redirect approved delivery. The caller
must filter hidden clocks, known-clock fills and private content **before** enqueue.
This ticket does not implement rendering, approval/publication effects or automatic
announcements. Do not enqueue a raw engine draft.

Ownership is checked against the tick. Content is non-blank and at most 2000
characters; IDs are canonical snowflakes. Split larger approved output into stable,
individually keyed records in the later renderer. A campaign-scoped key deduplicates
identical intent creation; changing its tick/recipient/kind/content returns
`:delivery_conflict`. Records and their jobs roll back with the outer transaction.
Job args contain IDs/generation only, never content, tokens or whole drafts.

## Send safety and retry policy

Each job commits a `sending` reservation before network I/O. Each reservation has a
generation and attempt count, preventing stale jobs/late results from overwriting
a newer retry. Outcomes:

| State | Meaning / behavior |
| --- | --- |
| pending | No send claimed yet; disabled bots snooze without claiming. |
| sending | A network operation may be in flight; no second automatic send. |
| sent | Definitive receipt saved with message/channel IDs; all retries are no-ops. |
| failed / retryable | Explicit rate-limit rejection, or failure before the private message was attempted; retry after 60 seconds, up to ten attempts. |
| failed / permanent | Forbidden (including blocked DMs), missing targets, invalid payloads or authentication rejection; no automatic retry. |
| ambiguous | Timeout, uncertain 5xx, unknown response/exception, or recovered interrupted reservation; no automatic resend. |

Nostrum handles REST buckets/global rate limits. Unknown message-send errors are
conservative: a server may have accepted a message even if the response was lost.
Discord message requests use a stable, generation-specific nonce with
`enforce_nonce: true`, also reducing duplicates from Nostrum's own transport
requeues. Discord checks nonce uniqueness only for the past few minutes; this is
**not exactly-once delivery** and not a reason to automatically resend ambiguous
records. A late definitive result may settle its own ambiguous reservation, but
never a newer generation.

`Deliveries.list_deliveries/1` and `fetch_delivery/2` are campaign-scoped, DM-only
reads. After current DM authorization, retry an individual failed record with:

```elixir
Deliveries.retry_delivery(campaign.id, delivery.id, delivery.generation)
```

A sent/pending/sending record cannot be retried. An ambiguous record requires
`confirm_ambiguous: true`, after checking Discord and accepting possible duplication.
Retries increment generation and enqueue a new job atomically; concurrent/stale
retry requests return `:stale_delivery`. Worker recovery converts an interrupted
sending claim into ambiguous without sending again. If the interrupted job had
already exhausted its attempts and was discarded, an authorized operator can retry
that original Oban job once to classify its outstanding claim; this does not resend
it. Only then consider a confirmed ambiguous delivery retry. Delivery never applies
game state or calls tick publication. Fix/retry delivery without republishing the tick.

Only bounded error classes/reason atoms cross the transport boundary. Discord
responses, exception messages, webhook URLs and private content are not recorded
in worker errors/logs. Do not enable packet tracing or dump library process state.
