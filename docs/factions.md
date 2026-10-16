# Factions

Factions belong to one campaign and currently contain a required `name` (up to
200 codepoints), an optional `description`, and UTC timestamps. Names need not
be unique. Deleting a campaign cascades to its factions.

`AsyncWorlds.Factions` is the shared boundary for the DM dashboard and HTTP
API adapters. Open **Factions** in the dashboard navigation (`/factions`) to
create, edit, or permanently delete campaign factions. Deletion prompts for
confirmation and targets the server-selected editor record. A faction with current
memberships cannot be deleted: `delete_faction/2` returns
`:faction_has_memberships`. Explicitly remove memberships first so link removal is
retained in history. No implicit membership cascade is performed.

HTTP routes are documented in [HTTP factions](http-factions.md). All verified
members of the configured Discord server can use `/faction list` and
`/faction show faction:<id>` without a character. Replies are private, but
**names and descriptions are campaign-readable**, not DM secrets. The list
shows IDs and names; show includes the description. Missing or foreign faction
IDs return the same friendly not-found message. Writes remain DM-only.
Re-register commands with `mix discord.register_commands` after deployment.

Factions have no tick effects. Updates currently use last-write-wins semantics;
there is no faction version precondition.

Build the scope from the server-loaded campaign and **verified** DM identity,
never from actor or campaign IDs supplied in a request body:

```elixir
scope = %{campaign: campaign, discord_user_id: verified_discord_user_id}

Factions.list_factions(scope)
Factions.create_faction(scope, %{name: "The Guild", description: "A trading alliance"})
Factions.get_faction(scope, faction_id)
Factions.update_faction(scope, faction_id, %{name: "The Merchants"})
Factions.delete_faction(scope, faction_id)

# New and existing form changesets (not persisted):
Factions.change_faction(scope)
Factions.change_faction(scope, faction_id, %{name: "Preview"})
```

Each DM call refreshes authorization and campaign configuration under the
campaign row lock via `DMAccess`. Results are `{:ok, value}` or `{:error, reason}`;
validation failures return a changeset. Missing, malformed, and cross-campaign
faction IDs return `:not_found`. Authorization errors follow `DMAccess`, including
`:unauthorized`, `:stale_campaign`, `:invalid_scope`, and `:invalid_id`.

Campaign ownership is assigned by the context and ignored in editable attrs.
Only name and description can be changed. Dashboard and HTTP reads and mutations
require a DM scope, including form changesets.

`list_campaign_factions(guild_id)` projects only IDs and names;
`get_campaign_faction(guild_id, faction_id)` projects ID, name and description.
These read-only functions are for trusted interfaces that verify guild membership
before calling them. They never resolve characters or debug personas. Discord's
dispatcher checks application, configured guild and authenticated member identity
before routing these member-level commands. These projections do not expose
membership counts, member identities or roles.

## DM memberships

[Memberships](memberships.md) documents the shared `AsyncWorlds.Memberships`
operations for joining, role editing, leaving, faction members and character
affiliations. They retain tick-linked history atomically and remain descriptive,
DM-only state with no gameplay/permission effects. Membership dashboard controls
and HTTP operations remain follow-up work.
