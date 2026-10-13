# DM quest library and operations (ENG-17 / ENG-30 / ENG-31 / ENG-32)

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

## Branching/cyclic quest authoring (no JSON required)

Open **Quest library & editor** from `/quests` (`/quests/library`). Empty libraries
offer **New quest**; existing imported/released revisions offer **Edit a working
copy**. Working copies are persistent but never appear in assignment controls.

1. Give the quest a name and a stable **Content identity** (letters, numbers,
   hyphens/underscores). After release that identity cannot change.
2. Write the entry node's narrative. Add ordered fixed choices with labels,
   outcome text and destinations selected by human-readable node descriptions.
   Add a node for each destination, choose a **Start node**, and explicitly mark
   terminal nodes as endings. Endings must have no choices; continuing nodes need
   at least one choice. IDs are allocated once and preserved behind the forms.
   Destinations may return to the same node, branch, or form cycles. A reachable
   ending is not required. Use **Move up/down** to reorder nodes or choices;
   order does not change identities, the start, or destinations.
   **Remove node** warns about inbound links before confirmation. Links from
   retained nodes (and a removed start) stay broken, not silently redirected.
   Save them for later repair using the destination/start selectors. Remove
   choices explicitly before changing a node to an ending; the last node cannot
   be removed.
3. **Save working copy** accepts incomplete text and references. Refresh or reopen
   its library link to resume. Unsaved typing remains only in the current tab.
4. **Validate & release revision** checks all text, unique IDs, references,
   conditions/effects and ending/choice consistency using the shared definition
   validator. Errors identify field paths (node/choice indices start at zero).
   Failed releases write nothing, including no partial draft/name changes.
   The read-only directed graph updates on every local edit without loading
   revisions or locking the campaign. Start/ending markers and arrows show all
   outcomes, including imported rolled branches, self-loops and multiple inbound
   links. Textual node/connection lists support keyboard navigation. Select a
   graph node, connection or diagnostic to focus the matching form.
   Broken start/destination references are release blockers with exact source
   node/choice/outcome paths. Unreachable nodes are **nonblocking warnings**:
   reachability considers every outcome, regardless of conditions or runtime
   eligibility. Cycles and quests with no reachable ending are valid.
5. Return to **Assign released revisions** and select the released revision using
   the existing audited assignment controls. Releasing again appends a revision;
   existing assignments and frozen tick inputs still use their original revision.

Example: **Meet the harbourmaster** entry narrative, **Introduce yourself** choice,
**The harbourmaster smiles** outcome, destination **Welcome aboard** marked as an
explicit ending. Save before completing the destination, refresh, repair it, then
release and assign. `/quest` exposes the pinned entry and fixed choice; submission,
close, private review and publication complete the ending through normal controls.

The editor displays its working version and base revision. Saves/releases reject
concurrent saves, releases, and imports that changed the latest base. A conflict
retains local text: **Inspect saved copy** reloads persisted content without erasing
the recovery snapshot; **Recover work as separate quest** persists that snapshot
with a new content identity. It does not overwrite/rebase the changed quest.
To edit that quest's latest revision, select its latest released revision and start
a new working copy. Editing an older revision cannot replace a newer base.

## Rolled choices and critical bonuses

Use **Convert to rolled** on a fixed choice, inspect the warning, then confirm.
Conversion keeps the identity, label, conditions and fixed outcome as **success**.
Partial/failure start blank: supply each branch's text and destination. Choose an
integer **1–3 d6** pool. Highest die **6 = success**, **4–5 = partial**, **1–3 =
failure**. At least two sixes still use success, then apply the ordered critical
bonus effects **after** the ordinary success effects.

Add **clock_delta** (campaign clock + signed integer), **set_flag** (key, boolean /
integer / string value, player visibility), or **clear_flag** (key). Move bonuses
up/down to choose execution order; remove them explicitly. Boolean values are
`true` or `false`. Resources are deferred. Save incomplete work and reopen its
working-copy link; pools, branches and bonus order persist before release.

**Convert to fixed** requires confirmation: it keeps success as the fixed outcome
and drops the pool, partial/failure and critical bonuses. Cancel preserves all work.
There is no automatic mode change when editing a pool or submitting a mode field.
Character flag equality conditions and ordinary outcome effects are now editable,
using the same typed controls as critical bonuses. Choose hidden/disabled behavior
for unmet AND conditions. See the [flag authoring checklist](dm-console.md#flag-authoring-checklist-eng-33).
Unsupported imported fields, other conditions and opaque effects remain intact and
read-only; opaque effects cannot be edited/removed through list controls. Conversions that
would discard opaque imported data are unavailable; use corrected re-import or
explicitly remove the whole choice instead. Every outcome remains visible in the
graph without normalization. There are no drag-drop, resources, rollback, AI or
new API editors, and no automatic choice-to-ending conversion. Retained IDs stay
stable. Forms support up to 100 nodes, 100 choices per node, 100 conditions per choice,
and 100 effects per outcome or critical bonus list,
with text at most 8000 bytes (quest names at release: 200 bytes).

After assignment and player submission, close the tick and open its **private
review**. Use the selected die's reason form to reroll only that die; unrelated dice
remain unchanged. Use the character's outcome selector with a reason to override
success/partial/failure, or its blank option to restore the recorded dice. A forced
success does not invent a two-six bonus. Inspect narration and proposed effects,
then confirm publication once: only publication applies progression, flags and
clocks atomically. Stale review controls require refresh, not an overwrite. See
[quest review](quest-review.md) for the audit and publication details. Rehearse
with offline controlled tests, not random critical hunting in a real campaign.
Authoring/releasing may continue during review because they append content only;
assignment/intervention locks and the publication guard remain unchanged.

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
