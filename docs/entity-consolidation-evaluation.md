# Entity and relationship consolidation evaluation

Status: investigation and recommendations, including a second-pass design review;
not an approved implementation specification. Recommendations below are proposed
unless describing an existing contract. Recording this discussion does not approve
implementation or settle the open design choices.

The follow-on [world model design](world-model-design.md) records the agreed,
simplified first slice and supersedes the earlier extensive proposal. This
evaluation preserves the investigation and recommendations, not additional scope.
Owner decisions defer primary factions, world-revision/precondition machinery,
and archive/delete lifecycle design; retain tick-linked link state changes,
optional membership roles, free-text location kinds, and DM-only relationships.
See ENG-80 for the decision record.

## Summary

`game_master_core` is a strong blueprint for a world-building layer in
`async_worlds`. Consolidate its capabilities here incrementally rather than
merging implementations or extracting a shared library now.

The projects have complementary responsibilities:

- **game_master_core:** campaign knowledge—entities, descriptions, relationships,
  organisation, and discovery.
- **async_worlds:** campaign execution—character ownership, quest revisions,
  frozen inputs, resolution, review, and publication.

Descriptive relationships should not implicitly become game mechanics.

This evaluation is based on static inspection of schemas, contexts, migrations,
controllers, documentation, and tests in both repositories. Neither test suite
was run as part of the initial investigation. After documenting the evaluation,
`mix precommit` passed in `async_worlds` (769 tests, zero failures). The older
project's suite was not run. Findings describe the inspected code, not verified
production behaviour.

## Current capabilities

| Area | game_master_core | async_worlds |
| --- | --- | --- |
| Factions | Content, tags, pinning, public flag, relationships | Campaign-scoped name and description |
| Locations | Content, type, parent/children, tags, relationships | Campaign-scoped name and description |
| Characters | Descriptive RPG records, faction membership, locations | Optional Discord ownership, typed flags, state version |
| Notes | Standalone campaign knowledge, linkable to other entities | Character-owned journals; not an equivalent |
| Quests | Descriptive records, hierarchy, objectives, links | Immutable executable revisions and character progression |
| Relationships | All pairings of five entity types, including same-type links | No equivalent general entity-link system |
| Discovery | Cross-entity search, tags, pins, hierarchy, relationship traversal | Primarily domain-specific interfaces |

The older relationship model uses 15 join schemas, covering every pairing of
characters, factions, locations, quests, and notes.

### Source references

Paths below are relative to the `async_worlds` repository root.

Older project:

- `../game_master_core/lib/game_master_core/links.ex`
- `../game_master_core/lib/game_master_core/entity_tree.ex`
- `../game_master_core/lib/game_master_core/search.ex`
- `../game_master_core/lib/game_master_core/locations.ex`
- `../game_master_core/lib/game_master_core/locations/location.ex`
- `../game_master_core/lib/game_master_core/characters/character_faction.ex`
- `../game_master_core/lib/game_master_core/characters/character_location.ex`
- `../game_master_core/lib/game_master_core/notes/note.ex`
- `../game_master_core/lib/game_master_core/quests/quest.ex`
- `../game_master_core/test/game_master_core/links_test.exs`
- `../game_master_core/test/game_master_core/entity_tree_test.exs`

Current project:

- `lib/async_worlds/factions.ex`
- `lib/async_worlds/locations.ex`
- `lib/async_worlds/dm_access.ex`
- `lib/async_worlds/characters/character.ex`
- `lib/async_worlds/journals/entry.ex`
- `lib/async_worlds/quests/quest.ex`
- `lib/async_worlds/quests/revision.ex`
- `lib/async_worlds/ticks/snapshot.ex`
- `lib/async_worlds/ticks.ex`

## Capabilities to bring across

### First-class relationships

Relationships are the most valuable missing capability. The older project treats
a link as more than two IDs. Depending on the pairing, it can carry:

- Relationship type and description
- Strength and active/inactive status
- Additional metadata
- Faction role and primary membership
- Current-location status

Preserve that concept, but distinguish structured domain relationships from
narrative associations.

| Relationship | Recommended treatment |
| --- | --- |
| Character belongs to faction | Typed membership, role, optional primary status |
| Character occupies location | Explicit current-location operation |
| Faction operates at location | Typed presence/base relationship |
| Location is inside location | Parent hierarchy |
| Faction allied with faction | General relationship with defined directionality |
| Quest concerns faction/location | Descriptive association, not assignment or eligibility |
| Note explains entity | Knowledge association |

For example, linking a quest to a location must not automatically require the
character to be there. Any such requirement needs an explicit rule.

### Location hierarchy

An optional parent supports useful containment structures:

```text
Region
└── City
    └── Harbour
        └── Warehouse
```

Bring across parent relationships, location kinds, tree queries, and breadcrumbs.
Add same-campaign parent validation, full cycle prevention, and explicit
parent-deletion behaviour.

The older location changeset rejects self-parenting, but does not perform the
fuller cycle validation present in its quest changeset. Do not copy that gap.

Prefer optional location kinds initially rather than adopting the older required,
fixed taxonomy unchanged.

### Standalone world notes

Older notes should not become journals here.

`AsyncWorlds.Journals.Entry` has character ownership, author attribution, creation
receipts, and private/public semantics. Those are meaningful constraints, not
incidental fields.

Introduce separate campaign-owned notes for lore, organisations, events, DM
preparation, secrets, discoveries, and reference material attached to entities.
Journals can eventually reference world entities without becoming the general
campaign document store.

### Search and relationship browsing

After relationships and notes exist, restore:

- Campaign-wide search
- Shared tag filtering
- Related-entity panels
- Location trees
- Bounded graph queries

Use nodes plus edges as the graph response, deriving tree views where useful.
The older `EntityTree` uses a visited set to avoid cycles, but consequently omits
some relationships when the same entity is reachable through multiple paths.
A containment tree and a relationship graph are different projections.

Pinning is also useful, but its scope should be decided explicitly: campaign-wide
curation and personal bookmarks are not necessarily the same feature.

## Boundaries to preserve

### Context-level authorization

Retain `DMAccess.run/2` as the shared boundary for web, HTTP, and Discord
operations. It refreshes authorization under the campaign row lock.

The older contexts sometimes explicitly assume the controller already checked
permissions. Its low-level `Links` API accepts entity structs without a scope.
Do not port that trust model.

Relationship operations here should:

1. Authorize through the shared context.
2. Fetch both endpoints within the campaign.
3. Assign ownership and endpoint IDs programmatically.
4. Validate editable metadata separately.

Correctness must not depend on which interface calls the operation.

### Executable quests versus descriptive associations

The projects use “quest” for different things. Here, quests include immutable
revisions, pinned assignments, conditions, effects, and frozen resolution inputs.
Do not replace those with the older mutable quest/status/objective model.

Initially attach descriptive links to the stable quest record. If a relationship
later influences eligibility or outcomes, give it explicit revision and snapshot
semantics.

See [Quest domain](quest-domain.md) and [World resolution](world-resolution.md).

### Existing identity conventions

The older project uses UUID entity IDs; this project generally uses integer IDs.
There is no need to change current IDs for conceptual consistency.

A future importer can maintain:

```text
source project + entity type + source UUID → local ID
```

Map older `game_id` ownership to `campaign_id`. Do not import the older
user-ownership model wholesale.

## Implementation lessons from the older code

The older code provides useful behaviour and test examples, but should not be
copied unchanged.

### Bulk-link atomicity

`Links.create_multiple_links/2` documents all-or-none behaviour, but itself maps
over inserts without a transaction and continues after errors. Some callers
correctly provide an outer transaction; the standalone function does not uphold
its documented guarantee.

New batch operations should own their transactional contract explicitly.

### Endpoint identity and editable metadata

Older link creation merges metadata over endpoint attributes, and join
changesets cast endpoint IDs. New code should keep endpoint identity outside
editable metadata and reject or ignore endpoint fields in metadata input.

### Symmetric-link uniqueness

Same-type links check both directions before inserting, but their database
uniqueness is on the ordered pair. Concurrent reversed inserts require stronger
protection, such as canonical endpoint ordering with database constraints.

Directionality must be explicit: alliances can be symmetric, whereas containment,
command, or influence may be directional.

### Traversal cost

Relationship traversal repeatedly calls `links_for/1`, issuing per-type queries
for expanded entities. Depth limits do not bound graph breadth.

New queries should have explicit node/edge budgets, stable ordering, and batched
fetching rather than recursive per-node database access.

### Repeated dispatch

The older `links.ex` is approximately 1,740 lines, with additional repeated
dispatch in contexts and controllers. Preserve the unified interface without
recreating that maintenance burden.

### Testing

Reuse older tests as behavioural examples, supplemented with:

- Campaign-isolation and fresh-authorization tests
- Endpoint identity protection
- Concurrent uniqueness enforcement
- Batch rollback guarantees
- Hierarchy cycle rejection
- Node and edge visibility filtering
- Traversal-budget behaviour

## Second-pass review: what to improve when implementing again

The follow-up discussion endorsed the recommendations as useful, while asking
that the older design be reconsidered before implementation. The aim is to
restore the world-building experience, not reproduce the old schema field for
field or merely rewrite its code more cleanly.

The following are proposed directions, not settled API or storage decisions.

### Domain operations versus descriptive references

Separate meaningful domain relationships from general descriptive associations.
Membership, current position, containment, and references have different rules.
A unified query interface need not mean one generic mutation interface.

Illustrative operations might include joining a faction, setting a primary
membership, moving a character, and reparenting a location. Their names and module
boundaries remain undecided. Explicit operations provide a place to enforce
permissions, cardinality, history, and future mechanical rules.

A note mentioning a faction or a quest concerning a location can remain a
descriptive association without changing membership, eligibility, or game state.

### Relationship semantics before storage

The older system generally permits one link per entity pair with a free-text
relationship type, and treats same-type links as bidirectional. Reconsider those
assumptions before selecting the new storage design.

For each supported relationship, define:

| Question | Example |
| --- | --- |
| Is it directional or symmetric? | Commands is directional; allied with can be symmetric |
| Can multiple relationships share endpoints? | A character can be both a member and a creditor of a faction |
| Is it single-valued? | A character has at most one current location |
| Does it have a lifecycle? | Membership starts, ends, or resumes |
| Who can see it? | Public allegiance versus secret allegiance |
| Does it affect mechanics? | Explicit eligibility rule versus descriptive context |

A faction's bases should not automatically follow the same model as a
character's current position. Likewise, historical and current membership need
not be represented by deleting and recreating an otherwise identical link.

Typed tables remain a reasonable starting point for membership and containment.
Storage for open-ended narrative relationships remains an open decision; the
initial typed-table recommendation is not a commitment to reproduce all 15 join
tables.

### Secrecy as part of the model

An entity can have a campaign-readable name and summary alongside DM-only plans
or secret relationships. Whole-entity public/private flags cannot express all
of those distinctions.

Start with campaign-readable summaries, separate DM-only material, and explicit
relationship visibility. Character-specific discovery is a possible later
capability, not a first-slice requirement.

Apply the same visibility policy to search, graph traversal, related-entity
panels, and counts—not just detail pages. Hidden associations must not become
visible through another projection.

### Current state, audit history, and fictional history

Distinguish three questions:

- **Current state:** where is the character and which factions do they belong to?
- **Audit history:** who changed the record, through which operation, and why?
- **Campaign history:** when did the change become true in the fiction, if relevant?

For example, a character leaving one faction after a tick and joining another is
potentially useful campaign history, not just an overwritten role field.

Explicit domain operations with audit records are a proportionate starting
point. Full event sourcing is not proposed. Tick-effective dates or relationship
history should be introduced only where their semantics are needed.

Do not automatically soft-delete every entity. Decide archival and deletion
behaviour deliberately, especially for records referenced by quests or published
history.

### Consistency and concurrent editing

In addition to the implementation lessons above, propose:

- Immutable relationship endpoints; changing a target is a distinct operation.
- Atomic replacement of a current location or primary membership.
- Database-enforced uniqueness rather than check-before-insert alone.
- Transactional batch operations with explicit rollback guarantees.
- Same-campaign validation and full hierarchy cycle prevention.
- Stale-editor protection where concurrent changes could silently overwrite work.

These are foundational guarantees, rather than later interface polish. The
specific versioning and auditing scope still needs to be decided.

### Everyday navigation before a graph editor

Keep containment trees and relationship graphs distinct. Prioritise useful
entity pages, related-entity lists, search, and relationship editing before a
large visual graph editor.

A bounded nodes-and-edges query can support future exploration without requiring
a graph editor in the first delivery.

The older search contract also deserves revision: `total_results` counts returned
rows rather than all matching rows, limits and offsets apply per entity type,
and ordering lacks a unique tie-breaker. Choose explicit pagination/count
semantics and deterministic ordering for the replacement.

### Avoid accidental requirements

Do not import older fields simply because they already exist:

- Required character class and level assume a particular style of game.
- A required fixed location taxonomy may not fit every setting.
- Generic relationship strength from 1–10 needs a defined purpose to be useful.
- A shared pinned flag may conflate campaign curation and personal bookmarks.
- Independently editable content and plain-text copies can drift apart.

Choose one authoritative content representation and derive plain-text/search
projections where needed. The representation and legacy conversion rules remain
open; no editor or content format has been selected.

### Design work before the first implementation

Settle three bounded areas before implementing the proposed first slice:

1. Entity content and visibility: summaries, private notes, ownership, archival.
2. Relationship semantics: membership, presence, containment, descriptive references.
3. Change lifecycle: authorization, concurrency, audit, eventual tick integration.

Then use faction membership and location hierarchy to test those choices. The
objective is a more intentional model, not maximum generality.

## Recommended structure

Keep separate domain tables, with a unified relationship and query interface:

```text
Characters / Factions / Locations / Notes / Quests
                  ↓
       Relationships context
                  ↓
     Search and graph projections
```

For structured domain relationships in the initial implementation, favour typed
join tables. They retain real foreign keys and support membership/current-location
constraints directly. As clarified in the second-pass review, storage for
open-ended narrative relationships is still undecided.

Avoid a bare polymorphic table containing only
`source_type/source_id/target_type/target_id`: ordinary foreign keys cannot
enforce its endpoints.

A shared entity registry could support generic edges later, but introduces
identity and lifecycle machinery that is not yet justified. A unified API does
not require a universal entity table.

Likewise, do not extract a shared library between the projects yet. First prove
the model inside `async_worlds`; the authorization, ownership, and lifecycle
contracts currently differ substantially.

## Visibility and content migration

Current faction and location names/descriptions are explicitly campaign-readable
through Discord. They are not suitable destinations for blindly importing older
DM material.

An `is_public` boolean alone does not distinguish internet-public,
campaign-readable, owner-only, and DM-only audiences.

Recommended policy:

- Preserve existing campaign-readable descriptions.
- Add explicitly private notes/content separately.
- Default imported secrets and relationship metadata to DM-only.
- Filter graph edges as well as nodes: a visible entity must not reveal a hidden
  association.
- Define content conversion before import. The older `content` and
  `content_plain_text` fields are not automatically equivalent to current
  descriptions or journal bodies.

See [Factions](factions.md), [Locations](locations.md), and
[Journals](journals.md) for current contracts.

## Suggested delivery order

### 1. Location hierarchy and faction membership

Deliver optional parent/kind fields, containment queries, and character–faction
membership with role and primary-status rules.

This provides immediate value using existing entities and establishes campaign,
authorization, and relationship patterns without disturbing the tick engine.

### 2. Character location and faction presence

Add explicit operations and database-enforced cardinality. Define whether a
faction has one headquarters, multiple bases, or another model rather than
assuming it behaves like a character's current position.

### 3. World notes and descriptive relationships

Add campaign knowledge notes, faction diplomacy, character connections, and
quest references. Establish visibility before exposing these to players.

### 4. Search and graph browsing

Provide shared dashboard/API projections, with deliberately narrower Discord
outputs. Bound traversal and preserve all returned edges rather than forcing
them into a tree.

### 5. One-way legacy importer

Require explicit game-to-campaign mapping, source UUID mapping, visibility
review, content conversion, and dry-run reporting. Make repeat imports
idempotent through durable source identity mappings.

### 6. Mechanical integration only when required

Any location or faction data used by resolution must enter frozen snapshots and
publication validation. The pure resolver must not query live relationship
state. Descriptive-only changes need not acquire mechanical significance merely
because the graph exists.

## Decisions to settle before implementation

- Which relationships need explicit domain operations rather than generic link mutations?
- Which relationship kinds are directional, symmetric, or single-valued?
- Can one entity pair have multiple distinct relationships?
- Which relationships need start/end history or fictional effective times?
- Which relationship fields are campaign-readable versus DM-only?
- Are pins campaign-wide or personal?
- What happens when a parent location or linked entity is deleted?
- Which edits need optimistic concurrency or audit history?
- What authoritative content format should world notes use, and how is legacy content converted?
- Which legacy fields have a current user need rather than being inherited assumptions?
- What pagination, count, and ordering contract should cross-entity search expose?
- What storage best fits narrative relationships without weakening endpoint integrity?
- Will any first-slice relationship influence gameplay, or remain descriptive?

## Recommendation

Start with **location hierarchy plus character–faction membership**. Restore the
older project's useful world-building capabilities incrementally while keeping
this project's stronger authorization, privacy projections, and deterministic
tick lifecycle intact.
