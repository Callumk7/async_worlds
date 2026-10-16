# Faction memberships (ENG-83)

`AsyncWorlds.Memberships` manages current character–faction memberships and their
retained link history. This is a DM-only shared domain API, also used by the DM
dashboard (ENG-86). HTTP operations (ENG-87) remain follow-up work.

## Operations

Build the scope from a server-loaded campaign and a verified DM identity, never
from ownership or actor fields in request bodies:

```elixir
scope = %{campaign: campaign, discord_user_id: verified_discord_user_id}

Memberships.join(scope, character_id, faction_id)
Memberships.join(scope, character_id, faction_id, %{role: "Scout"})
Memberships.edit_role(scope, membership_id, %{role: "Captain"})
Memberships.edit_role(scope, membership_id, %{role: nil})
Memberships.leave(scope, membership_id)
Memberships.list_faction_members(scope, faction_id)
Memberships.list_character_affiliations(scope, character_id)
```

Every operation freshly authorizes under the shared campaign lock via `DMAccess`.
Targets are looked up within that campaign. Missing, foreign, malformed and
out-of-range IDs return `{:error, :not_found}`; valid integer IDs or numeric
strings are accepted. Authorization errors follow `DMAccess` (`:unauthorized`,
`:stale_campaign`, `:invalid_scope`, `:invalid_id`).

Mutations return `{:ok, membership}` or `{:error, reason_or_changeset}`. Validation
errors, including duplicate joins, return an Ecto changeset. A repeated leave or
editing a removed membership returns `:not_found`. A role-only no-op succeeds
without retaining another change. Query results are `{:ok, memberships}` ordered
by ascending membership ID; both `character` and `faction` are preloaded for DM
interfaces. Queries validate their endpoint even when the list would be empty.

## DM dashboard

Select an existing faction on `/factions` to manage its members, or a character
on `/characters` to manage their affiliations. Both panels show current links
and roles, allow joining through a campaign-scoped selector, and support role
editing (blank clears) and confirmed leave. Rejoining creates a new current link
without losing previous history. Create/save a new endpoint before adding links.

The page-selected endpoint is server-pinned. Role edits and leaves must reference
a current membership belonging to that endpoint, not merely another membership
in the same campaign. Injected endpoint, ownership and gameplay fields are
ignored. Each event uses the shared freshly authorized context operations;
revoked sessions/DM access cannot write. These panels are DM-only and do not
change existing HTTP or Discord player projections.

## Current state and integrity

`faction_memberships` contains a local ID, campaign, character, faction, optional
role, and UTC timestamps. All ownership/endpoints are set programmatically by the
context and never cast from editable metadata. Only role can be edited; moving a
membership to another endpoint requires leaving and joining instead. Role is
free text (at most 200 Unicode codepoints, valid UTF-8 without NUL). Blank/null
clears it. There is no controlled role taxonomy or permission meaning.

A database unique index permits only one current membership per character/faction
pair. Same-campaign composite foreign keys enforce both endpoints. Supported
writes serialize on the campaign row, including competing joins: one succeeds,
the duplicate returns a uniqueness changeset. Characters may join multiple
factions. There is no primary faction, arbitrary metadata or visibility editor.

## Retained changes and gameplay boundaries

Join, role edit and leave run through `LinkHistory.transact/2`. The current-state
mutation and retained change commit atomically; any validation or history failure
rolls both back. Before/after snapshots contain `character_id`, `faction_id` and
`role`, with nil for absence on join/leave. Unchanged roles produce no record.
The retained change stores the membership ID plus typed character/faction endpoint
identities, verified actor, stable change ID and recording timestamp.

Leaving removes only the current row. Rejoining creates a new current ID, but
history queries by either endpoint still include earlier joins/edits/leaves.
History does not depend on live membership rows or endpoint records surviving.

Tick attribution is the current open tick or actual next tick, including setup,
resolving and review. No tick row must exist yet and opening it never recalculates
earlier associations. See [Link history](link-history.md).

Memberships are descriptive only: they grant no application/Discord permissions,
do not mutate characters or their ownership, flags or `state_version`, and do not
affect quest eligibility, assignments, submissions, progression, frozen resolution
inputs, drafts or published output. They produce no deliveries or jobs. They
remain editable while gameplay inputs are locked. Existing character mutation
locks and expected-version checks are unchanged. Player character and Discord
faction projections, including list counts, expose no memberships or roles.

## Basic reference safety

`Factions.delete_faction/2` returns `:faction_has_memberships` while any current
memberships reference it. Explicitly leave those memberships first, retaining
removal history, then retry deletion. The existing dashboard explains this error;
HTTP DELETE returns 409 `faction_has_memberships`. No implicit membership cascade
bypasses change recording. Character deletion has no supported context/UI/API;
the database rejects deleting any character with current memberships. The
existing whole-campaign deletion cascade still removes all campaign state and
history. No archival, retention administration or lifecycle framework is added.

## Verification

- `test/async_worlds/memberships_test.exs`: transitions, endpoint assignment,
  validation/no-ops, queries, fresh authorization, database constraints, reference
  safety, history rollback, lifecycle attribution, privacy and gameplay isolation.
- `test/async_worlds/memberships_concurrency_test.exs`: real PostgreSQL lock waits
  for duplicate joins and DM revocation, using supervised tasks and messages.
- `test/async_worlds_web/membership_live_test.exs`: both dashboard panels, join,
  role edit/clear, confirmed leave/rejoin, validation, endpoint injection,
  campaign/panel isolation, removed targets, revocation, retained tick attribution
  and unchanged ownership, flags, quests, submissions, deliveries and jobs.
- Existing faction controller/LiveView tests cover the new delete conflict.

See [World model design](world-model-design.md) for the first-slice scope.
