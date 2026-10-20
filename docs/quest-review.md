# Quest review and publication (ENG-20)

Implemented through the shared tick pipeline, DM console and
[HTTP review API](http-tick-review.md).

Review retains the original frozen submissions, pinned revision/node/position and
choice identity. A selected die is identified by the ENG-18 JSON identity tuple;
reroll changes only that effective value, auditing identity and old/new values,
actor and mandatory reason. Original Roll rows remain immutable. All other dice
are preserved, even when an override removes downstream effects. No operation
adds submissions or changes roll requirements. Any future newly required roll
must be explicitly reserved before resolving; the pure resolver never uses RNG.

Outcome overrides select only configured failure/partial/success of rolled
choices. Fixed choices cannot be overridden. Critical bonus applies only when the
effective outcome is success AND reviewed/preserved dice naturally contain two
sixes. Forced non-success suppresses bonus; forcing success cannot fabricate one.
Clearing an override restores the dice-derived outcome. Player narration replaces
only result text, not effects; clearing restores authored outcome text.

Every edit replays frozen inputs with the full audit-derived review state. Frozen
submission eligibility is not rechecked against intervening quest effects.
Authored effects run in existing order, followed by background rates and ordered
latched clock triggers. Next choices use final flags/clocks. No resources or graph
authoring or full history UI is included.

Server validation requires current draft UUID, current campaign DM, nonblank
reason and exact frozen submission identity (or exact die identity). Preview and
publication verify canonical audit replay, not arbitrary supplied draft JSON.
New closes use v3 snapshots with explicit frozen personal delivery routes: linked owners,
labelled DM-controlled characters, and optional additive DM copies. Preview and outbox
use the same frozen routes; persona/copy-setting changes after close do not reroute
messages or invalidate a draft. Gameplay, ownership and campaign routing checks remain
in force. Existing v1/v2 snapshots retain their prior validation/output semantics.

Publication checks frozen/live campaign routing, character ownership/flags, active
progression IDs/revisions/nodes/position versions and clocks before applying state.
Approved payload/output history and original rolls are immutable. Publication,
progressions, flags, quest availability, world clocks, deliveries/jobs and campaign
transition commit together; one logical outbox intent per recipient/message.
Repeated publication rejects; stale competing reviews reject; failures roll back.
Private output includes only authored/reviewed result narration and safe final node
text/choice labels with generic unavailable hints, routed to frozen player IDs.
DM-only review previews exact public, DM and player messages. No network I/O takes
place in resolution, review or publication.

## Operations and UI

`Ticks.edit_draft/6` accepts these additional strict operations (atom or string keys):

```elixir
%{type: "reroll", identity: die_identity, old_value: displayed_value}
%{type: "outcome", input_revision: snapshot.revision, input: frozen_submission, value: "partial"}
%{type: "player_narration", input_revision: snapshot.revision, input: frozen_submission, value: "Approved result"}
```

Nil clears outcome/narration overrides. Fixed choices support narration only.
Narration/reasons reject blank, NUL and text longer than 2000 graphemes. Reroll values are
server-generated only after authorization/current-draft/target checks; `/7` has a
trusted injectable roller for controlled offline tests. The audit stores old/new
values and identity. Replay checks the draft UUID chain and reroll old values.
Original recorded rolls remain the worker's input; audit-derived effective dice
are used only for review/canonical verification. Repeated worker jobs cannot
replace a reviewed or published draft.

At `/ticks/:id/review`, player sections show the pinned choice, before/after node,
effective outcome, final next choices, individual die controls and narration.
Every form carries the current draft identity. Exact private preview identifies
each DM/player recipient and includes approved dice, result text and safe final
node/choices. Hidden flags, conditions, audit reasons and hidden-clock details
never enter player messages. Stale editors disable controls until reload.

Unlock availability persists in `quest_unlocks` with one character/quest pair,
and is frozen on subsequent closes. Repeated unlock triggers are logged no-ops.
`Quests.list_unlocked/3` is a freshly authorized DM read; availability is not an
automatic assignment. Legacy snapshots without the availability array mean empty
availability. Appended quest definitions remain compatible with a frozen turn;
live assignment revision/position/routing changes do not.
