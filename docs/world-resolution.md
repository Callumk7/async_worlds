# World-only resolution decisions (ENG-4)

## Ordering and latching

Version-1 snapshots resolve in ascending clock ID order (the snapshot ordering
must agree). Quest choices and resource assignments remain reserved phases before
background rates; quest conditions remain a reserved phase after triggers. This
resolver does not implement quest/resource effects; adding those inputs requires
an explicit snapshot/engine contract extension.

Before rates, scan all incomplete, initially full clocks in ascending ID order.
Latch their completion eligibility, and the first member of each race as winner.
Then apply signed background rates in ascending ID order, latching each newly full
clock immediately. A latch survives later negative changes: an initially full
clock with a negative rate still fires. A racing loser may still receive its rate,
but cannot replace the winner. Completed clocks never move or fire. Paused clocks
skip rates, but an initially full paused clock still fires.

After all rates, process latched winners in ascending clock ID order. Complete the
winner and its racing partner, then process the winner's triggers in stored order.
Only the winner fires; the loser keeps its resulting fill and completes silently.
Both members must be reset by management before the race can run again. Reset is
an input-management operation, never an automatic resolution effect.

## Trigger semantics and termination

Supported actions are notify_dm, world_news, and start_clock. News and notifications
are draft intents only, not delivery. Starting unpauses an incomplete target,
preserving its fill/rate/configuration; completed targets remain unchanged.
Starting never reapplies a background rate or resurrects a completed clock.
Initially full targets already have their own latch; starting cannot add another.
Cyclic start links therefore cannot recurse: each eligible clock fires at most
once and each configured trigger is visited once. No trigger currently adjusts
fill. Future fill-changing triggers must explicitly extend this ordering/latching
contract rather than introducing recursive execution.

## API and draft contract

`AsyncWorlds.Ticks.WorldResolver.resolve(snapshot)` accepts a version-1
`Ticks.Snapshot` (including one loaded from the database) and returns
`{:ok, payload}` or `{:error, :invalid_snapshot}`. Invalid/unsupported schemas,
ordering, clock ownership, racing pairs or trigger references fail closed.

Payloads use string keys and contain schema_version, input_revision, tick_number,
resulting clocks (including hidden clocks), race_winners, ordered effects, ordered
trigger_results, source-labelled log, world_news and dm_notifications. This is
DM-only data, not a public Discord payload. Entries have deterministic sequence
numbers; sources identify background tick operations and individual clock trigger
indices. Effects are clock changes; trigger_results include notification/news
intents and start outcomes, including no-ops. Only actual state changes enter the
log as clock changes; all trigger outcomes enter it as trigger results.

The resolver performs no database, network, random, clock-time or UUID operations.
Identical snapshots yield identical payloads, suitable for `Ticks.put_draft/5`.
ENG-7 owns job orchestration; ENG-8 owns validated review/recomputation/publication.
Re-resolve the original frozen snapshot, not the resulting draft clocks.
