# Editable quest submissions (ENG-16)

## Boundary decisions

Shared domain APIs accept guild ID and **verified** Discord user identity. Never
accept a player-selected character. Components carry an exact identity map:
`tick_id`, `progression_id`, `revision_id`, `node_id`, `position_version` (atom
keys). IDs are positive integers, not arbitrary strings. `position_version`
changes on every actual DM move, preventing an old component from becoming valid
again after a move away and back. Swaps produce a new progression ID. Interfaces
must refresh through `Submissions.player_state/2` to obtain current identity.

`submit/4` replaces the one choice for that character/tick; `clear/3` is
idempotent for the current identity. Both reauthorize ownership, tick openness,
assignment/revision/node/version and eligibility of the relevant choice under
the campaign lock. Clear requires no choice when there is no submission, but
revalidates an existing choice. Player reads expose only their own choice and
safe quest projection. DM reads/counts reauthorize against current campaign state.

Assignments and actual position changes invalidate open submissions immediately.
Ownership changes also invalidate them. Flag/clock changes can alter eligibility:
reads/counts regard an ineligible submission as unready; close revalidates it and
freezes it as an invalidation, not a turn. It may be replaced while open. No
invalid choice is executed and no missing/invalid submission has a penalty.
Appending content never changes a pinned assignment or a submitted choice.

Assign/swap/end/move and all character mutations lock during resolution/review,
sharing the campaign-before-tick lock order used by submissions and close.
Authoring immutable new quest revisions remains allowed after close. Serialized
submit/change/clear racing close either commits before the freeze or receives
`tick_closed`; stale/foreign components receive `stale_identity` without changes.

## Snapshot v2

New closes capture the existing world input plus `quest_inputs`: all campaign
characters (identity, name, ownership and typed flags), active progressions
(including position version), immutable quest revisions and stable quest metadata,
valid submissions, and explicit invalidations. Ordered arrays use ascending DB
IDs. Clock trigger targets and their full definitions are consequently frozen,
including unassigned quest unlock targets. Everything is captured once inside
close's transaction; retry returns the original revision and data.

Counts (`active`, `submitted`, `missing`) are informational and count only valid
active-character choices. Close does not depend on readiness. Missing characters
remain at their frozen nodes; submission collection does not advance progression.
Private definitions, flags, submissions and snapshots are DM-only.

The quest executor is ENG-18, not this issue. The world-only resolver supports v2
only when there are no valid quest submissions or quest-dependent triggers. It
explicitly rejects unsupported quest work with `quest_executor_required`, never
silently publishes a world-only result that drops submitted turns. Such closes
still freeze and queue successfully, but remain resolving until the executor is
implemented. Existing v1 snapshots remain supported. Discord components and
commands are ENG-19; minimal DM intervention UI is ENG-17.
