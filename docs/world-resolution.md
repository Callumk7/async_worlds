# Quest and world resolution decisions (ENG-4 / ENG-18)

## Ordering and latching

Version-1 snapshots resolve in ascending clock ID order (the snapshot ordering
must agree). Version-2 snapshots also resolve frozen valid quest submissions in
ascending character ID order, before the reserved resource phase, background
rates and clock triggers. Effects run in authored list order, with critical bonus
effects appended after success effects. Missing/invalidated submissions do nothing.
Only one submitted turn runs per character: cycles never auto-follow another choice;
ending nodes complete the draft progression. Frozen eligibility is validated against
the original snapshot, not rechecked after another character's effects. Final
next-node conditions use all resulting clocks and flags, after triggers, including
for characters who did not submit. Resource mechanics remain unimplemented.

Before quests or rates, scan all incomplete, initially full clocks in ascending ID order.
Latch their completion eligibility, and the first member of each race as winner.
Latch after every individual quest clock delta (including bonus effects), then
apply signed background rates in ascending ID order, latching each newly full
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

Supported actions are notify_dm, world_news, start_clock, and (v2 only) set_flag
and unlock_quest. Set-flag changes only its frozen target character. Unlock-quest
records availability for its frozen character/quest target, never assigns or
interrupts a progression; repeated unlocks are logged no-ops. News and notifications
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
Version-2 validates the frozen quest contract and executes submitted choices and
dependent triggers. `resolve(snapshot, review, rolls)` consumes an ordered list
of individual recorded dice; missing, extra, out-of-range or wrongly associated
dice return `invalid_rolls` without a draft. Fixed choices consume no dice.
1–3 d6 keep highest: 6 success, 4–5 partial, 1–3 failure; at least two sixes use
success plus configured bonus effects. The pure engine never generates randomness.
V2 adds resulting characters, progressions, unlocked_quests, private_results,
next_nodes and rolls to the DM-only payload. The log includes every die, authored
quest effect (including no-ops), character change and outcome alongside existing
clock changes/trigger results, with contiguous sequence numbers and source labels.
Invalid snapshots still cancel for investigation. See [quest-submissions.md](quest-submissions.md).

## Durable roll boundary and scope

`Ticks.record_quest_rolls/4` is a trusted worker API. It locks campaign then tick,
validates the frozen snapshot and revision, and inserts missing individual d6 rows
in a separate committed transaction **before** `ResolveTick` calls the pure engine.
Each row references the snapshot and stores the entire frozen submission, zero-based
die index and value. Stable identity is a JSON tuple of input revision, character ID,
progression ID, quest revision ID, node ID, position version, choice ID and die index;
JSON encoding avoids delimiter collisions in authored IDs. Database uniqueness and
immutable rows plus lifecycle locks make concurrent/retried reservations reuse the
same dice without even invoking the random callback. A crash after reservation but
before draft insertion reuses the committed pool. Duplicate workers cannot overwrite
a reviewed draft. Changed downstream effects do not generate or replace unrelated
dice. Controlled roll replacement is possible as pure input; durable reroll/review
operations are provided by ENG-20; see [quest-review.md](quest-review.md).

`Ticks.fetch_draft(guild_id, verified_actor_id, tick_id)` reauthorizes the current DM
and scopes retrieval to the campaign. Player projections continue reading live state;
resolution sends no narration/draft deliveries and mutates no live characters,
progressions or clocks. ENG-20 adds audited die/outcome/narration review and atomic
quest/world publication with exact private output; see [quest-review.md](quest-review.md).
Resources remain unimplemented.
ENG-7's [durable worker](durable-work.md) owns job orchestration; ENG-8's
[audited review/publication](tick-review-publication.md) owns validated edits and
atomic publication. `resolve(snapshot, review)` accepts clock-delta and narration
overrides, producing the same deterministic contract plus a `review` map when
nonempty. Clock overrides replace the selected background delta and label effects
with a `review:tick:...:clock:...` source. Re-resolve the original frozen snapshot,
not the resulting draft clocks.
