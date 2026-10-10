# Campaign clocks (ENG-5)

`AsyncWorlds.Clocks` is the shared domain boundary. Interface handlers must first
use `Campaigns.authorize_dm/2`; pass the authorized campaign ID and a non-empty
source label (for example `dm:456`, `background:tick:3`, `quest:choice:12`).
Every successful management operation writes an immutable before/after audit
snapshot in the same transaction. Rejected operations write nothing. Reads and
clock-ID lookups are campaign scoped; lists have stable ascending ID order.

## State and operations

- Sizes are 4/6/8. Creation, editing and signed adjustment clamp fill to 0..size.
  Resizing clamps the existing fill. Rate is a signed integer, default zero.
- Visibility is public/known/hidden. These are DM-side records, not player-safe
  payloads: player interfaces must omit hidden clocks and known-clock fill.
- Pause skips background rates, not explicit adjustments. Use `edit_clock/4`
  with `paused: true/false`; this is audited like any other edit.
- Reaching full does **not** complete automatically. `complete_clock/3` explicitly
  latches completion and returns the winner's actions without delivering them.
  Completed clocks reject edits and adjustments until reset. Background and start
  helpers leave completed clocks unchanged; completion cannot fire twice.
- `reset_clock/3` clears fill and completion, preserves configuration and pause,
  and resets both racing members together. A race is a reusable contest; resetting
  only one member would leave an ambiguous winner from the previous contest.
- Pairing assigns a shared UUID to exactly two clocks. Self-links, foreign clocks,
  completed members and any existing membership are rejected. Unpair clears both
  members. Membership fields cannot be edited through ordinary attributes.
  Management serializes on the campaign row, including pairing/unpairing.

The minimal [DM console](dm-console.md) exposes these operations. `edit_clock/5`
optionally accepts the previously loaded clock as its final argument, comparing it
under the campaign lock and returning `:stale_clock` before any write if it has
changed. `recent_audits/2` provides bounded descending-ID dashboard history.

## World-only triggers

`triggers` is an ordered list of typed embeds:

```elixir
[
  %{type: "notify_dm", text: "The ritual is ready."},
  %{type: "world_news", text: "Storm clouds gather."},
  %{type: "start_clock", clock_id: 42}
]
```

Notification/news require non-blank text (maximum 2000 characters) and cannot have
clock IDs. Start requires an existing other clock in this campaign and cannot have
text. Flags/quest-unlocks are not supported. A start **unpauses** an incomplete
clock, preserving fill, rate and triggers; it never resets/resurrects a completed
clock. Trigger execution/delivery belongs to draft resolution/publication, not
management. Cyclic start references are harmless because start doesn't fill or
fire a clock recursively.

## Frozen inputs and integration contract for ENG-2 / ENG-4

The campaign's persisted `clock_mutations_locked` guard rejects **all** management
writes while resolution/review is outstanding (`{:error, :tick_locked}`). It
survives restarts and cannot be changed by campaign setup. All management and
guard transitions acquire the same campaign row `FOR UPDATE`, eliminating the
check-then-write race.

Tick closing must wrap its transition, `Clocks.lock_mutations/1` and reading frozen
inputs in **one outer Repo transaction**. Publishing must similarly acquire the
campaign lock, verify the tick/revision, apply approved results/audits, mark the
tick published and `Clocks.unlock_mutations/1` in one transaction. The guard is an
integration primitive, not a standalone tick lifecycle; do not expose unlock to
normal management UI, and never unlock just to run management during publication.
The ENG-2 lifecycle now implements this protocol through `AsyncWorlds.Ticks`;
see [tick-lifecycle.md](tick-lifecycle.md). Management also checks resolving/review
tick status, and unlock refuses while a frozen active tick exists. The publication
writer must honor this same locking protocol; this module cannot protect
uncoordinated raw SQL.

`Clocks.Rules` helpers operate on schemas or equivalent frozen maps and have no
Repo/delivery dependencies. `adjust`, `background`, `start`, `reset` and `complete`
return new state. `complete(winner, loser)` assumes the resolver supplied the
validated racing partner (or nil), marks both complete and returns only winner
actions. Resolve the first fill in engine operation order and latch its winner
before later effects can undo the fill. For simultaneous initial full clocks,
ascending clock ID is the tie-break. The resolver must retain that latch through
its trigger phase; simply scanning final fill is not enough. Starting during the
trigger phase cannot retroactively apply a background rate in that tick.

The management completion operation is an explicit DM-side action; it returns
intents but does not send messages. Draft resolution must use pure helpers rather
than management functions, leaving published state untouched until publication.
