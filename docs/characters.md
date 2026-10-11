# Characters (ENG-13)

This is the minimal milestone-2 bootstrap, not the full character/quest/resource admin. A DM can link players, edit names or Discord ownership, and set/clear typed facts at `/characters`. `/character` retrieves the invoking player's permitted state privately. Re-register the development guild commands using the existing registration task to add it.

## Shared domain boundary

`AsyncWorlds.Characters` is shared by LiveView and Discord; callers do not write character records directly.

DM APIs accept the previously loaded `%Campaign{}` plus the **authenticated** Discord DM identity:

- `create_character(campaign, dm_id, attrs)`
- `list_characters(campaign, dm_id)`
- `get_character(campaign, dm_id, character_id)`
- `update_character(campaign, dm_id, character_id, attrs)`
- `set_flag(campaign, dm_id, character_id, key, flag)`
- `clear_flag(campaign, dm_id, character_id, key)` (idempotent)

All return `{:ok, result}` or `{:error, reason_or_changeset}`. Every operation starts a transaction, locks and reloads the campaign, checks the current DM, and rejects changed guild/DM/public-channel configuration (`:stale_campaign`). An old DM receives `:unauthorized`. Setup's upsert takes the same row lock, so concurrent setup cannot slip between authorization and persistence. Reads are protected too. Character IDs are positive database IDs and always scoped to that campaign; invalid/missing/foreign IDs return `:not_found`. Snowflakes use the existing strict unsigned-64-bit type; malformed actor IDs return `:invalid_id`. Failed validations, authorization, uniqueness or flag updates leave all character fields unchanged.

`attrs` may contain `name`, `discord_user_id`, and `flags`. `campaign_id`, primary keys and timestamps are never cast. The DM may intentionally relink ownership; a conflicting relink fails atomically. A non-null campaign foreign key and PostgreSQL unique index on `(campaign_id, discord_user_id)` enforce one character per identity per campaign, without an application uniqueness precheck. A database check also guards canonical snowflakes. Separate campaigns may link the same Discord identity.

## Flags

Flags are a bounded JSON object (up to 100 keys). Keys start with a lowercase letter, contain only lowercase letters/digits/underscores, and are at most 64 bytes. Each fact has **exactly** these string-keyed fields:

```json
{
  "owes_the_guild": {"type": "boolean", "value": true, "player_visible": false},
  "debt": {"type": "integer", "value": 3, "player_visible": true},
  "title": {"type": "string", "value": "Captain", "player_visible": true}
}
```

Types are `boolean`, `integer`, or `string`, validated against native JSON values without coercion. Integers are limited to the JSON-safe range ±9007199254740991. Strings are valid UTF-8, at most 2000 bytes, and exclude NUL (U+0000), which PostgreSQL JSONB cannot store. Character names are limited to 200 Unicode codepoints and also reject invalid UTF-8 and NUL before persistence. Nulls, floats, containers, unknown types/fields and missing/non-boolean visibility are rejected. Visibility is always explicit; there is no implicit player-visible default. All supplied flags are validated before any profile/ownership/flag change is persisted. `update_character` replaces the whole flag object when supplied; omitting it preserves flags. Use `set_flag`/`clear_flag` for one fact, serialized on the campaign row, preserving other facts. Storage is JSONB; shape/type validation lives in the shared changeset, not in interfaces.

The small web editor accepts JSON values (e.g. `true`, `3`, `"Captain"`) and an explicit Hidden/Visible selector. Set an existing key to edit its type, value or visibility.

## Player identity and privacy

`player_character(guild_id, verified_discord_user_id)` accepts an identity obtained from a trusted Discord interaction (or a future verified session), **not arbitrary player parameters**. There is deliberately no character-ID argument. It returns only:

```elixir
{:ok, %{name: "Rook", flags: %{"debt" => %{"type" => "integer", "value" => 3}}}}
```

The projection constructs a whitelist: no internal character/campaign IDs, Discord IDs, timestamps, associations, visibility metadata or future schema fields. Hidden flags are omitted entirely, including their names; malformed stored facts fail closed. No character returns `{:error, :not_found}`.

The Discord dispatcher supplies only the authenticated guild member identity, never a top-level user or command option. `/character` has no options; forged character/user-ID options are rejected. It inherits the existing private defer/edit/followup adapter path (ephemeral flag 64 and suppressed mentions), guild/application checks, chunking, and failure handling. No proactive DM or public message is sent.

LiveView uses the existing authenticated-DM live session, with session reauthorization on every event and revocation/expiry handling. Domain authorization is additional protection, not a substitute for the session check.

## Deliberate boundaries

No quest/node/resource fields, submission processing, character effects, draft progression or full milestone-3 admin are introduced. These facts are current live state; existing world-only tick snapshots/resolution remain unchanged and do not consume characters. Future quest work must freeze character inputs and apply only approved progression at publication, extending this whitelist explicitly rather than serializing schemas. Normal tests use sandbox PostgreSQL, the existing Discord fake adapter and session helpers; no OAuth or live Discord requests are required.
