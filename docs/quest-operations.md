# Minimal DM quest operations (ENG-17)

## Operator workflow

Sign in with the configured campaign DM and open **Quests** (`/quests`).
Alternatively, use a character's **Quests** link on `/characters`.

1. Link players through `/characters`. Existing character name/ownership and
   typed flag controls remain there; no SQL is required to bootstrap characters.
2. Select a character, choose a validated quest **revision**, enter an audit
   reason, and **Assign quest**. Assignment starts at that revision's start node.
   An ending start node completes immediately. The same revision can be assigned
   to multiple characters; their assignments and submissions are independent.
3. Inspect the active quest, pinned revision, node narrative and position version.
   **Replace quest** ends the old assignment and starts the selected revision.
   Even replacing with the same revision creates a new independent assignment.
4. **Move character** selects a node only from the currently pinned revision.
   Moving to an ending completes the assignment. A move to the existing node is
   a no-op, preserving the choice and emitting no misleading audit record.
5. **End quest** stops an active assignment without marking it completed.
   The character can then receive a new assignment.

No content editor, graph view, resource administration or import workflow is
introduced. Empty content explains that validated definitions must first be added
through `Quests.create_quest/4` / `append_revision/4` (see quest-domain.md).

## Authorization, invalidation and locking

All routes, disconnected/connected mounts, navigation and events use the existing
DM-only session checks. Shared `Quests` reads and writes additionally authorize
against the freshly locked campaign row. Foreign character/revision/progression
IDs and nodes outside the pinned revision are rejected, including forged events.
The action targets the server-selected character, never a posted character,
progression, actor or campaign ID.

Assign/swap/end and actual moves use ENG-16's invalidation policy. Open choices
are cleared on an intervention; old component identities cannot change the new
assignment. Current eligibility is determined from current facts and clocks.
There is no penalty for a cleared or missing choice. Other players are unaffected.
The screen explains these effects before submission and confirms disruptive
operations. A result does not apply choice effects or rolls; those belong to the
quest tick executor.

During resolving/review, the screen disables interventions and explains how to
return to the active tick. Domain writes still enforce the lock even if an old
open tab posts an event. Refresh after publication re-enables the controls.
Existing frozen inputs are never edited by intervention actions.

Operational editors pass the exact server-read progression (or nil for an
unassigned character) as `expected_progression`. Comparison happens under the
campaign lock before any invalidation/write. A stale editor is rejected, refreshed
and instructed to inspect the changed assignment; there is no automatic retry.
This includes two unassigned tabs racing to assign, and move-away/back changes
in the position version. Trusted domain callers can omit this optional check for
intentional current-state interventions.

## Audit contract

`assign/5`, `swap/5`, `end_quest/4` and `move/5` retain the previous arities through
optional keyword arguments: `reason` and `expected_progression`. Web controls
require an explicit reason (1–2000 Unicode code points, no NUL); existing trusted
callers receive a descriptive default when the reason is omitted.

Every actual successful action appends a `quest_interventions` record atomically
with the progression mutation and open-submission invalidation. It records the
campaign, character, active tick if any, freshly authorized DM identity, action,
reason, timestamp, before/after assignment/revision/node/status/position-version,
and number of open choices cleared. Assignment's before state is nil. Rejected,
locked and stale actions leave progression, choices and audits unchanged.
Database triggers reject audit UPDATE/DELETE while the campaign exists, permitting
only campaign teardown. The shared `list_interventions/3` reader is DM-only and
returns the ten most recent records for that campaign character. The UI shows this
small operational history, not a full history browser. Player projections never
include audits or intervention reasons.

Tests cover domain authorization, immutable audits, transaction rollback,
independent assignments, submission invalidation/eligibility, stable LiveView
selectors, stale editors and resolution/review locks. Normal tests use offline
OAuth stubs and sandbox PostgreSQL.
