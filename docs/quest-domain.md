# Quest domain (ENG-14)

## Content and revisions

A campaign owns a quest with a stable `content_id`. Authoring appends an immutable
revision; existing assignments remain pinned to their original revision. Nodes
and choices have author-supplied stable string IDs, unique within a revision
(choices are globally unique within that revision). Choice array order is display
and resolution order. Cycles are valid. `ending: true` explicitly requires an
empty choice list; non-endings require choices. Revision rows and node indexes
are protected against UPDATE/DELETE in PostgreSQL. No deletion API is offered.

Definitions are strict string-keyed maps: `start_node`, `nodes`. ENG-15 adds a
versioned, atomic JSON import envelope and trusted operator commands; see
[quest-import.md](quest-import.md) and `priv/quests/harbor.json`.
Nodes: `id`, `text`, `ending`, `choices`, plus optional `public_summary` (valid
UTF-8 text, at most 1000 bytes, no NUL). Missing or whitespace-only summaries use
a generic public fallback; they never copy private narrative. This additive field
is compatible with existing version-1 imports and frozen definitions. Choices: `id`, `label`, `eligibility`
(`hidden` or `disabled`), `conditions`, `mode`, `outcomes`; rolled choices also
require `dice` (1–3) and `critical_effects`. Fixed outcomes have exactly `fixed`;
rolled outcomes exactly `success`, `partial`, `failure`. Outcomes: `text`,
`next_node`, `effects`. All next nodes must belong to this revision.

## Typed rules

Conditions are ANDed. A `clock_threshold` has `clock_id`, `operator` (`gte` or
`lte`), and integer `value` within the referenced clock's size. A `character_flag`
has `key`, `flag_type`, `value`: equality is type-sensitive, absent flags fail. Types
and values follow ENG-13 boolean/integer/string flags. Conditions cannot change
visibility or explain facts to players. Authoring validates thresholds against
current clock size. Frozen runtime validation preserves authored thresholds after
a clock resize: an unreachable threshold simply fails eligibility, without
invalidating unrelated choices or rewriting the pinned revision.

Effects run in list order: `clock_delta` (`clock_id`, integer `delta`), `set_flag`
(`key`, `flag` = ENG-13 type/value/player_visible), `clear_flag` (`key`). Flag
effects target the acting character, never arbitrary characters. Clock deltas
clamp to size and do not fire triggers here. No resource types are supported.
Rolled resolution consumes recorded d6s, keeps highest: 6 success, 4–5 partial,
1–3 failure. At least two sixes selects success and appends `critical_effects`
after success effects. Fixed choices accept no dice or critical configuration.

## Progression, privacy and authority

Assignments persist separately per character, pinned to revision and node; a
partial unique index permits only one active assignment per character. Assigning
an ending immediately completes it. DM assign/swap/end/move operations use fresh
campaign authorization and serialize on the campaign row. There is no player
mutation endpoint. The pure Rules transition takes frozen definition/state and
recorded dice and returns new state; it does not publish or persist effects.
The implemented submission/resolution/publication services use this primitive
inside their authorized tick lifecycle, never as an immediate player-state write.

Player projection looks up the fresh guild and verified player identity, never a
player-supplied character ID. It whitelists node text and ordered choice IDs and
labels. Ineligible hidden choices are omitted. Disabled choices have only the
generic hint `Not available right now.`; raw conditions, clock fills, effects,
flag keys/values (including hidden facts), outcomes and DM metadata are never
included. Ending projections have no choices.

`freeze_definitions` returns JSON definition copies with revision identities for
authorized callers; it is DM-only. Authoring updates cannot affect those copies
or pinned assignments. ENG-16 adds full v2 tick inputs via `Submissions.freeze/2`
in the close transaction; see [quest-submissions.md](quest-submissions.md).

## Public activity summaries (ENG-63)

The node editor offers **Public activity summary (optional)**, independently of
private narrative. Save/reopen and release use the existing stale-editor and
immutable-revision boundaries; new releases never repin existing characters.
Clearing the field removes it and restores the generic fallback. Keep secrets out
of explicitly authored public text; it is not automatically redacted.

`Quests.public_activities(campaign, dm_id)` is a freshly authorized, campaign-locked
read used by DM briefing preparation. It returns a stable character-ID-ordered
list containing only `character_id`, `name`, `summary`, and `decision_required`.
Text comes from each character's pinned node, not the latest library revision.
Missing summaries on active non-ending nodes say “A quest decision is required.”
Endings, ended paths, and unassigned characters require no decision; absent public
text says “No quest decision required.” Ending nodes may have explicit public text
while still requiring no decision. The pure `PublicActivity.project/3` helper
exposes only summary and decision requirement, never quest names, private text,
choices, flags, effects or conditions. Existing private player projections are unchanged.

These summaries now feed the implemented [tick-opening preview and durable public
briefing](tick-opening.md). Mutable quest-action announcements and quest custom
proposals remain unimplemented; independent private [Tension intentions](tension-commitments.md)
are available without quest nodes.

## DM operational controls

ENG-17 exposes assignment, replacement, ending and manual moves at `/quests`.
Shared operations are freshly authorized, audited and support an optimistic
`expected_progression` option. See [quest-operations.md](quest-operations.md) for
UI usage, stale-editor handling and immutable intervention history.

## Character/quest on-fill targets

Existing world triggers retain their behavior. `set_flag` targets exactly one
same-campaign `character_id` with `key` and typed `flag`. `unlock_quest` targets
exactly one same-campaign `character_id` and `quest_id` (stable quest row, not a
mutable node). Unlock means availability, not assignment or interruption of an
active quest. ENG-16 freezes these targets and definitions on close. ENG-18 executes them only
in the draft trigger phase, once per completed winner clock. They never mutate
live published state during resolution. ENG-20 publishes these with approved progression and flags atomically, including
idempotent quest availability. See [quest-review.md](quest-review.md).
