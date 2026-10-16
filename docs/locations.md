# Locations

Locations belong to a campaign and contain a required `name` (maximum 200
codepoints), optional `description`, optional free-text `kind`, optional `parent_id`,
and UTC timestamps. Names need not be unique. Existing locations remain roots
with no kind; IDs and descriptions are unchanged. Deleting a campaign cascades
to its locations. There are no coordinates, movement, character/faction links,
or mechanical tick effects.

## Shared context

`AsyncWorlds.Locations` provides the shared persistence and authorization boundary
for LiveView, HTTP, and Discord. DM calls accept a server-loaded campaign and
verified DM identity, never actor or ownership fields taken from request bodies:

```elixir
scope = %{campaign: campaign, discord_user_id: verified_discord_user_id}

Locations.list_locations(scope)
Locations.get_location(scope, location_id)
Locations.create_location(scope, %{name: "Harbour", description: "The city's docks."})
Locations.update_location(scope, location_id, %{name: "Old Harbour"})
Locations.delete_location(scope, location_id)
Locations.change_location(scope)
Locations.change_location(scope, location_id, %{name: "Preview"})
```

Each DM operation refreshes authorization and campaign configuration under the
campaign row lock via `DMAccess`. Returns `{:ok, value}` or `{:error, reason}`;
validation errors return an Ecto changeset, and missing or cross-campaign targets
return `:not_found`. Ownership is set programmatically and cannot be edited.
Updates currently use last-write-wins semantics, without a version precondition.

Campaign-readable functions are for trusted interfaces that **verify guild
membership before calling**:

- `list_campaign_locations(guild_id)` projects only IDs and names.
- `get_campaign_location(guild_id, location_id)` projects ID, name, description.

These reads never require a character or resolve a DM debug persona. Their
projections deliberately exclude kind, hierarchy and history.

## DM hierarchy (ENG-82)

```elixir
Locations.update_location(scope, location_id, %{kind: "neighbourhood"})
Locations.set_parent(scope, location_id, parent_id)
Locations.clear_parent(scope, location_id)
Locations.list_children(scope, parent_id)
Locations.list_children(scope) # roots
Locations.breadcrumbs(scope, location_id) # root through the location itself
```

Parenting is explicit: create/update/form attrs never cast `parent_id` or
ownership. Kind is ordinary optional metadata, not a taxonomy or rule. Each
hierarchy operation freshly authorizes under the shared campaign lock, including
queries. Missing, malformed and foreign endpoints return `:not_found`.
Children/roots are ordered by ascending ID. Breadcrumbs follow campaign-scoped
parents and fail closed after 100 nodes (`:hierarchy_too_deep`) or on a detected
cycle (`:location_cycle`). Parent validation uses the same bounded ancestor
traversal and rejects self/indirect cycles. Supported writers serialize on the
campaign row; direct database writes are not a supported hierarchy API.
The database also enforces same-campaign parent foreign keys and rejects
self-parenting.

Parent set/reparent/clear use `LinkHistory.transact/2`: current state and retained
containment changes commit atomically. Each record indexes the child and old/new
parents, stores explicit endpoint states (nil when no relationship exists), and
uses the current open tick or actual next tick. No-op parenting and descriptive
kind edits produce no link history. Links do not mutate characters, quests,
frozen inputs, publications or deliveries. See [Link history](link-history.md).

Deletion returns `:location_linked` if the location has a parent or children.
Explicitly clear those links first, recording their removal before deleting
endpoints. No silent cascade/reparent is performed by entity deletion, and
retained history survives endpoint deletion. Whole-campaign deletion retains its
existing cascade behaviour. This is basic reference safety, not archival or a
general entity lifecycle design.

Hierarchy operations and kind editing are also available in the DM dashboard
(ENG-85) and authenticated DM HTTP API (ENG-87). HTTP location DTOs additionally
include nullable kind and parent ID; existing Discord/member projections remain
unchanged. See [HTTP locations](http-locations.md).

## Interfaces

- **Dashboard:** open Locations in the navigation (`/locations`) to create, edit,
  and permanently delete locations. Name, description and optional free-text kind
  share the metadata form. Save a location first, then use the separate parent
  form to set/reparent it or select **No parent** to clear it. The parent save
  uses the shared tick-linked history operation; metadata and parent saves are
  intentionally independent. Root/child lists and clickable root-to-location
  breadcrumbs navigate the editor, ordered by stable IDs. Kind and hierarchy are
  labelled DM-only. Cycle, unavailable-parent, traversal-limit and linked-delete
  failures give actionable messages without exposing foreign records. Deletion
  prompts for confirmation and uses the server-selected editor record; explicitly
  clear its parent and each child's parent before retrying a linked deletion.
- **HTTP:** authenticated DM CRUD at `/api/campaigns/:guild_id/locations`;
  see [HTTP locations](http-locations.md).
- **Discord:** `/location list` and `/location show location:<id>` are available
  to every verified member of the configured server, without a character.
  The dispatcher verifies application, guild, and authenticated member identity.
  Replies are private with mentions suppressed, but **names and descriptions
  are campaign-readable**, not DM secrets. Foreign and missing IDs receive the
  same friendly not-found message. Writes remain DM-only.

Deploy the migrations. Existing Discord commands are unchanged by hierarchy
support; the original location slash commands require `mix discord.register_commands`
if not already registered.

## Verification

`test/async_worlds/location_hierarchy_test.exs` and
`test/async_worlds/location_hierarchy_concurrency_test.exs` cover the shared domain
and serialized cycle prevention. `test/async_worlds_web/location_hierarchy_live_test.exs`
and `test/async_worlds_web/location_live_test.exs` cover metadata and parent saves,
root/child/breadcrumb navigation, retained history/ticks, validation, referential
safety, expired sessions, DM revocation, and clearing private editor state.
