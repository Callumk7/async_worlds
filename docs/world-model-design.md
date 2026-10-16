# World model design — first slice

Status: **First-slice direction agreed. ENG-81 history foundation implemented;
hierarchy and membership features remain follow-up work.**

Sources: [entity consolidation evaluation](entity-consolidation-evaluation.md)
and the owner decisions recorded in ENG-80. This document supersedes the earlier,
more extensive draft. Recommendations in the evaluation are not additional
first-slice requirements.

## 1. Outcome

Add useful foundational world modelling to `async_worlds`:

- DM-managed location hierarchy with an optional free-text kind.
- DM-managed character–faction memberships with an optional role.
- Retained link state changes associated with ticks, providing data for future
  entity timelines.

Do not reproduce the older project's schemas or general link machinery wholesale.
Keep current-state tables and history separate; do not replace the quest engine,
character ownership model, or journals.

## 2. Owner decisions

| Topic | Decision |
| --- | --- |
| Tick attribution | Use the current open tick; if none is open, associate the change with the next tick |
| Relationship visibility | DM-only initially; defer broader visibility design |
| Membership | Optional role; no primary faction feature in this slice |
| Location kind | Optional free text, not a controlled taxonomy |
| Concurrency tokens | Defer new world revision/stale-editor machinery |
| Archive/delete lifecycle | Defer broader lifecycle design |
| Closed-tick behaviour | No new world-edit lock/review workflow; apply the same tick attribution rule |
| HTTP compatibility | No new revision preconditions or compatibility migration |
| History | Retain link state changes now; timeline rendering comes later |

Existing character state-version checks and gameplay lifecycle locks are not
removed. Deferring new concurrency features does not remove transactions,
authorization, foreign keys, uniqueness, or cycle prevention.

## 3. Existing contracts

- Faction/location names and descriptions are already campaign-readable through
  trusted Discord interfaces. Keep those projections unchanged.
- DM operations use fresh authorization and campaign-scoped lookups. Continue
  using `DMAccess` and the campaign lock for shared world operations.
- Existing character mutations have their own tick lock and database-maintained
  `state_version`. Membership writes must not update character records merely
  to reuse that machinery.
- Quests use immutable executable revisions and frozen tick inputs. Descriptive
  memberships and containment do not change eligibility, flags, assignments,
  progression, resolution, or publication.
- Journals remain character-owned entries, not general world notes.

See [Factions](factions.md), [Locations](locations.md),
[Characters](characters.md), [Quest domain](quest-domain.md), and
[Personal history](personal-history.md).

## 4. Location hierarchy

Extend locations with optional `parent_id` and optional free-text `kind`. Existing
locations remain roots with no kind; preserve their IDs and descriptions.

Rules:

- Zero or one parent; any number of children.
- Parent and child must belong to the same campaign.
- Reject self-parenting and indirect cycles.
- No required taxonomy or automatic kind/rank restrictions.
- Parent changes are explicit domain operations and produce retained link
  changes. Clearing a parent is also a state change.
- Kind is ordinary descriptive metadata, not a game rule.

Use real foreign keys with same-campaign enforcement and a database self-parent
check. Validate ancestor cycles inside the shared campaign transaction. All
supported hierarchy writers use that boundary.

Provide stable child lists and breadcrumbs; bound hierarchy traversal defensively.
No coordinates, travel mechanics, or automatic character movement.

## 5. Faction membership

Add a typed current-membership table containing local identity, campaign,
character, faction, optional role, and timestamps.

Rules:

- One current membership per character/faction pair; characters can belong to
  multiple factions.
- Database uniqueness and same-campaign foreign keys enforce endpoint integrity.
- Endpoints and ownership are assigned by the context, not editable role metadata.
- Joining creates a membership; editing changes its role; leaving removes the
  current membership without erasing its retained history.
- Rejoining can create a new current membership row. Historical queries must
  identify the endpoint entities, not depend solely on that row surviving.
- No primary faction field, selector, operation, or index.
- Roles are descriptive and grant no application or Discord permissions.

Use focused membership operations rather than exposing raw join-table writes.
Module/function naming remains an implementation detail. Do not add arbitrary
metadata, generic strength fields, or a configurable visibility model now.

## 6. Retained link state changes

The requirement is **data for later timelines**, not a comprehensive
administrative audit subsystem.

For membership joins/leaves/role edits and containment changes, retain enough to
identify:

- Campaign and relationship kind.
- Both endpoint entities (including old/new parent for a reparent).
- Before and after state, including absence on creation/removal.
- Associated tick number/identity.
- Recording timestamp and deterministic ordering, such as a stable change ID.

Retain immutable change data atomically with the current-state mutation. Failed
operations leave neither partial state nor history. A no-op produces no state
change record. Historical records must not depend on the current membership row
continuing to exist. Trusted actor/source attribution can be included without
requiring a new audit viewer or reason-entry workflow.

### Tick association

Select the attribution under the campaign lock:

1. If a tick is open, associate the change with that tick.
2. Otherwise associate it with the next tick, including before the first tick.

Do not require the next tick row to exist before retaining a change, and do not
open a tick or send opening messages as a side effect. A campaign-scoped tick
number can durably identify that future association; a concrete tick foreign key
may be populated when available. A null foreign key alone must not lose the
intended tick association.

Use the actual lifecycle's next tick, including when an earlier tick is resolving
or in review. Implementation must verify the numbering behaviour rather than
assuming a non-open active tick is an open tick. Preserve the selected association
when the next tick opens; do not recalculate old changes from live campaign state.

No separate backdating, corrections workflow, effective-time system, or setup
tick is required now. Associating a change with a tick does not add it to the
resolution inputs or automatically publish it to players.

### Relationship to existing history

Existing tick snapshots preserve resolution inputs; publications preserve approved
results and outgoing content. Clock audits and quest interventions already retain
some tick-associated changes.

New link changes supply missing world-history data. Later history queries can
combine those records by campaign/tick and entity. No timeline UI, unified event
store, snapshot diffing, or expansion of resolution snapshots is needed now.

ENG-81 implements this foundation as `LinkHistory.transact/2` and DM-only
`list_changes/2`. Records use `(campaign_id, tick_number)` as the permanent tick
association, so future ticks require no history backfill. Endpoint identities are
retained in a typed `entity_refs` index, independent of live link rows. See
[Link history](link-history.md) for the implemented writer and query contracts.

## 7. Authorization, safety, and scope control

Each operation must:

1. Authorize the verified DM under the campaign lock.
2. Fetch all targets within that campaign; foreign/malformed/missing targets fail
   without leaking another campaign's records.
3. Validate relationship constraints.
4. Select tick attribution and atomically write current state and retained change.
5. Return a whitelisted result with no external delivery.

Keep hierarchy and membership details DM-only in this slice. Do not add them to
existing member responses, counts, player character projections, or Discord
commands. No visibility editor is needed until broader exposure is designed.

Use the existing world CRUD editing conventions rather than introducing a
campaign-wide `world_revision`, mandatory expected-version arguments, or HTTP
preconditions. Transactions still serialize supported writes and constraints
prevent invalid relationships; detecting every stale editor is deferred.

Do not add archive/restore, retention-policy administration, or a general deletion
framework. At schema integration, retain basic referential safety: a live foreign
key must not be left dangling and deleting a current link must not erase history.
Any necessary handling of existing destructive CRUD must be explicit and covered
by tests, not a silent cascade that bypasses change recording. Choose the smallest
safe integration behaviour during implementation; broader entity lifecycle design
is not a prerequisite for the whole slice.

## 8. Interfaces and delivery

### Shared domain and schema

Implement retained change storage/tick attribution, then hierarchy and membership
contexts with their constraints. Preserve existing records; do not infer links
from names, descriptions, flags, or legacy data.

### DM dashboard

- Locations: optional parent/kind editing, breadcrumbs and child navigation.
- Factions: member list, add/remove character, optional role editing.
- Characters: affiliations panel using the same shared membership operations.

Use existing authenticated-DM sessions, layout/form components and stable DOM IDs.
Do not add primary-faction, visibility, audit-viewer, or archive controls.

### HTTP

Expose the same DM operations using existing HTTP conventions and authentication.
Do not introduce new concurrency-token requirements or change unrelated clients.
Document only the new operations and any unavoidable referential-safety error.
Existing Discord member list/show output remains unchanged.

## 9. Verification

Feature-local tests must cover:

- Fresh authorization, campaign isolation, missing/foreign IDs, and trusted
  endpoint assignment.
- Database duplicate-membership/same-campaign constraints and hierarchy cycles.
- Join, role edit, leave, rejoin, parent set/clear/reparent, and no-op behaviour.
- Atomic rollback of current state and history.
- Attribution to an open tick, next tick before it exists, initial campaign setup,
  and changes while another tick is resolving/in review.
- Durable history after membership removal and opening the attributed next tick.
- Existing member projections reveal no new relationship/history data.
- No changes to character flags/generations, frozen inputs, quest state,
  published outputs, or deliveries from descriptive relationship edits.
- Basic delete/reference safety without implementing the deferred lifecycle suite.
- LiveView and HTTP operations use the shared domain boundary.

Run targeted tests and `mix precommit`. Concurrency tests use supervised processes
and message/monitor coordination rather than sleeps.

## 10. Deferred work

- Primary affiliation and other relationship semantics beyond membership roles.
- New optimistic concurrency tokens and HTTP preconditions.
- Archive/restore and broader deletion/retention policy.
- Player relationship exposure and character-specific knowledge permissions.
- Timeline rendering, publication of relationship history, and backdating tools.
- World notes, generic narrative links, graph editor, search/tags/bookmarks.
- Character movement, faction bases/territory, and mechanical integration.
- Legacy import or a shared package between projects.

These are future possibilities, not unfinished prerequisites of this slice.
