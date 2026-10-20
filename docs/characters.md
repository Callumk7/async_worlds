# Characters (ENG-13 / ENG-35)

This is the character/profile/fact editor connected to existing quest operations, not a resource or full historical admin. A DM can link players, edit names or Discord ownership, and set/clear typed facts at `/characters`. `/character` retrieves the invoking player's permitted state privately. Re-register the development guild commands using the existing registration task to add it.

## Shared domain boundary

`AsyncWorlds.Characters` is shared by LiveView and Discord; callers do not write character records directly.

DM APIs accept the previously loaded `%Campaign{}` plus the **authenticated** Discord DM identity:

- `create_character(campaign, dm_id, attrs)`
- `list_characters(campaign, dm_id)`
- `get_character(campaign, dm_id, character_id)`
- `update_character(campaign, dm_id, character_id, attrs, opts \\ [])`
- `set_flag(campaign, dm_id, character_id, key, flag, opts \\ [])`
- `clear_flag(campaign, dm_id, character_id, key, opts \\ [])` (idempotent)

Web mutations always pass `expected_character: server_loaded_character`. Under the campaign lock,
all three compare the same-campaign record's database-maintained `state_version`, returning
`:stale_character` before writes/invalidation on mismatch. A PostgreSQL UPDATE trigger advances
this generation for **every writer**, including tick publication; name/flag/ownership changes
away and back (ABA) cannot evade it. Timestamps are not used as conflict tokens. The additive
schema migration must be run through the normal deployment migration process, not automatically
on startup. Existing characters, flags and assignments are not converted or repinned. Trusted
callers may omit the option for intentional current-state mutations.

All return `{:ok, result}` or `{:error, reason_or_changeset}`. Every operation starts a transaction, locks and reloads the campaign, checks the current DM, and rejects changed guild/DM/public-channel configuration (`:stale_campaign`). An old DM receives `:unauthorized`. Setup's upsert takes the same row lock, so concurrent setup cannot slip between authorization and persistence. Reads are protected too. Character IDs are positive database IDs and always scoped to that campaign; invalid/missing/foreign IDs return `:not_found`. Snowflakes use the existing strict unsigned-64-bit type; malformed actor IDs return `:invalid_id`. Failed validations, authorization, uniqueness or flag updates leave all character fields unchanged.

`attrs` may contain `name`, `discord_user_id`, and `flags`. `campaign_id`, primary keys and timestamps are never cast. The DM may intentionally relink ownership; a conflicting relink fails atomically. A non-null campaign foreign key and PostgreSQL unique index on `(campaign_id, discord_user_id)` enforce one character per linked identity per campaign, without an application uniqueness precheck. Discord ownership is optional: null/blank means a DM-controlled character, and multiple accountless characters are allowed. Their labelled personal messages go to the campaign DM via frozen delivery routes. A database check also guards canonical snowflakes. Separate campaigns may link the same Discord identity.

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

The web editor accepts ordinary boolean (True/False select), integer (whole-number input),
and string (plain text) values plus an explicit Hidden/Visible selector. Quotes and whitespace
in strings are literal; empty strings are allowed. `Flags.parse/1` is the named form parser;
JSON decoding is not involved. **Edit** beside a fact preloads its key/type/value/visibility;
the key is read-only and pinned server-side even if a forged event posts another key. **New fact**
starts a fresh key. Save/clear rejects stale character snapshots without retrying: reopen the
character and inspect current facts before applying local changes again.

## Player identity and privacy

`player_character(guild_id, verified_discord_user_id)` accepts an identity obtained from a trusted Discord interaction (or a future verified session), **not arbitrary player parameters**. There is deliberately no arbitrary player character-ID argument. The verified-user API remains compatible; Discord debug calls use the shared `PlayerAccess` subject context instead, freshly checked against the current DM and persisted persona under the campaign lock. It returns only:

```elixir
{:ok, %{name: "Rook", flags: %{"debt" => %{"type" => "integer", "value" => 3}}}}
```

The projection constructs a whitelist: no internal character/campaign IDs, Discord IDs, timestamps, associations, visibility metadata or future schema fields. Hidden flags are omitted entirely, including their names; malformed stored facts fail closed. No character returns `{:error, :not_found}`.

The Discord dispatcher retains the authenticated guild member as the real actor, never a top-level user or player-supplied ownership option. The current DM may explicitly select a gameplay subject using `/debug`; this does not relink the character or change OAuth identity. See [single-account testing](discord.md#single-account-player-testing-including-live-campaigns). `/character` has no options; forged character/user-ID options are rejected. It inherits the existing private defer/edit/followup adapter path (ephemeral flag 64 and suppressed mentions), guild/application checks, chunking, and failure handling. No proactive DM or public message is sent.

LiveView uses the existing authenticated-DM live session, with session reauthorization on every event and revocation/expiry handling. Domain authorization is additional protection, not a substitute for the session check.

## Descriptive faction affiliations

[Memberships](memberships.md) provides separate DM-only character–faction joins,
optional roles, role edits, leaves and stable affiliation queries (ENG-83).
Membership writes use the shared campaign lock and retained link history; they
never update the character or advance its `state_version`, and do not adopt or
remove gameplay tick locks. Roles confer no permissions. Current player payloads
remain unchanged. Character deletion is not exposed; database foreign keys reject
deleting a character while it has current memberships. Explicitly leave first
when integrating any future deletion operation, retaining removal history.

## Journal ownership

[Player journals](journals.md) use the owner-approved **character-owned** policy:
relinking grants the new current owner access to all of that character's private
journal history and deletion rights. Former owners lose private access. Journal
original-author identity is attribution only. This deliberately differs from the
historical tick-result/submission ownership protections described in the Discord
documentation. DM personas follow the selected character's permissions; actual DM
attribution and explicit origin remain immutable server-set journal fields.

## Deliberate boundaries

The connected DM editor shows Discord ownership, active pinned quest revision/node/status,
the ten most recent DM-only intervention audits, and links to quest operations/content.
Quest operations link back to the selected profile. No deletion, archive, resources,
automatic content migration, or separate quest executor is introduced by the character editor.
Facts are current live state. The implemented quest tick pipeline freezes character
inputs at close and applies approved flags/progression only at publication; see
[quest submissions](quest-submissions.md) and [quest review](quest-review.md).
Player projections remain explicit whitelists rather than serialized schemas.
Normal tests use sandbox PostgreSQL, the existing Discord fake adapter and session
helpers; no OAuth or live Discord requests are required.
