# Manual ticks and frozen world inputs (ENG-2)

`AsyncWorlds.Ticks` is the shared domain API. Web/Discord handlers must authorize
with `Campaigns.authorize_dm/2` before calling it. There are no timers, submission
requirements, automatic closes, resolver jobs or Discord calls in this module.

## Lifecycle API

1. `open_tick(campaign_id)` opens tick `current_tick_number + 1`. The campaign
   counter is the last **published** tick number, not the open turn number.
   Repeated/concurrent opens return `{:error, :active_tick}`. A partial unique
   database index also prohibits multiple non-published ticks per campaign.
2. `close_tick(campaign_id, tick_id)` locks clock management, captures inputs and
   moves `open` to `resolving` in one transaction. Returns
   `{:ok, %{tick: tick, snapshot: snapshot}}`. Retrying close during resolving or
   review returns that same snapshot without re-freezing inputs or regressing
   status. Closing a published tick is an invalid transition.
3. `put_draft(campaign_id, tick_id, input_revision, payload, expected_draft_id)`
   appends a draft revision and moves resolving to `in_review`. The first worker
   passes nil (the default) as expected draft ID. Every subsequent review/recompute
   must pass the latest draft ID. Outdated input or draft identities return
   `:stale_input` / `:stale_draft`. Payload must be a JSON object; game semantics
   and recomputation belong to ENG-4, not this lifecycle layer.
4. `publish_tick(campaign_id, tick_id, expected_draft_id, apply_callback)` accepts
   only the current reviewed draft. It calls the trusted internal application
   callback with `%{tick: tick, snapshot: snapshot, draft: draft}`. The callback
   applies approved state, writes source-labelled audits and inserts delivery
   outbox rows in this transaction. Return `{:ok, value}` to proceed or
   `{:error, reason}` to roll back. After success, the tick becomes published,
   the campaign counter advances and management unlocks. Repeated publication
   returns `:already_published` **without calling the callback**.

Publication intentionally requires an explicit callback: ENG-4/ENG-7 implement
validated world effects and durable delivery. This is not a user-provided function
or an excuse to publish without applying the draft. It must only perform database
work, never network I/O or other irreversible effects. Exceptions also roll back
DB writes and leave the tick in review for retry. The callback's success value is
not persisted here; published records/outbox contents must be written by it.

## Frozen snapshot version 1

Snapshots are DM-only and contain:

- Campaign ID, Discord guild, DM, public channel and previous published number.
- The turn number.
- All clocks, including hidden and completed clocks, in ascending ID order,
  with name, size, fill, visibility, signed rate, pause/completion, racing group,
  ordered typed trigger payloads and campaign ownership.
- Explicit clock ordering, ascending-ID racing tie-break, and phase sequence:
  quest choices, resource assignments, background rates, clock triggers, then
  quest conditions. Quest/resource inputs will be added when those systems exist.

The snapshot has a schema version and a unique UUID input revision. There is
exactly one snapshot per tick. Drafts have unique UUID identities and increasing
integer revisions and refer to the captured input UUID. Snapshot and draft rows
reject database UPDATEs: review appends a new draft instead of rewriting history.
Read `fetch_snapshot/2` and `fetch_draft/2` only from DM-authorized interfaces.

Campaign setup may change live Discord configuration while resolving; the frozen
configuration remains unchanged. Later content changes after publication cannot
alter prior snapshots. The downstream resolver consumes the frozen data, not a
new live campaign/clock query.

## Transaction, privacy and integration rules

All lifecycle and clock writes take the same campaign `FOR UPDATE` lock before
any tick lock. This serializes competing transitions, clock edits and setup row
updates. A clock edit racing close either commits before capture and is included,
or returns `:tick_locked`; no live edit can disappear at publication. In resolving
and review, clock management checks both the persisted guard and active tick
status. `Clocks.unlock_mutations/1` refuses while a frozen active tick exists.
Publication marks the tick published before unlocking, in the same transaction.

No published game state changes at close or on draft writes. Player clock views
continue reading live clocks, with their usual visibility filtering. They must
never read draft payloads or snapshots. `latest_published_tick/1` is the last
published turn; `active_tick/1` exposes lifecycle/readiness only, not draft data.
All ID-based lookups and mutations require the owning campaign ID.

Invalid transitions return `{:error, {:invalid_transition, status, operation}}`;
missing/foreign records return `:not_found`. There is no cancel, reopen, skip-review
or published rollback transition. Failed resolution can retry with the same
snapshot; failed publication retains the approved draft for retry.

Concurrency tests use independent PostgreSQL connections and real commits, not
a shared sandbox connection, and clean up campaign-owned rows afterward.
