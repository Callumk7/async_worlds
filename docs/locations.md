# Locations

Locations belong to a campaign and contain a required `name` (maximum 200
codepoints), optional `description`, and UTC timestamps. Names need not be unique.
Deleting a campaign cascades to its locations. There are no coordinates,
parent locations, character/faction links, or tick effects at this stage.

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

These reads never require a character or resolve a DM debug persona.

## Interfaces

- **Dashboard:** open Locations in the navigation (`/locations`) to create, edit,
  and permanently delete locations. Deletion prompts for confirmation and uses
  the server-selected editor record.
- **HTTP:** authenticated DM CRUD at `/api/campaigns/:guild_id/locations`;
  see [HTTP locations](http-locations.md).
- **Discord:** `/location list` and `/location show location:<id>` are available
  to every verified member of the configured server, without a character.
  The dispatcher verifies application, guild, and authenticated member identity.
  Replies are private with mentions suppressed, but **names and descriptions
  are campaign-readable**, not DM secrets. Foreign and missing IDs receive the
  same friendly not-found message. Writes remain DM-only.

Deploy the migration and run `mix discord.register_commands` to register the
new slash commands.
