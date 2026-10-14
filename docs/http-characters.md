# Character and flag HTTP management (ENG-53)

All routes require the configured DM bearer credential and use
`/api/campaigns/:guild_id/characters` as their base. `guild_id` is the Discord
guild ID; character `id` is the campaign-scoped database ID, not a Discord ID.
See [authentication](http-api.md) and [HTTP conventions](http-conventions.md).

| Method | Path relative to base | Body | Success |
| --- | --- | --- | --- |
| GET | (base) | none | 200, `data: [...]`, ordered by character ID |
| GET | `/:id` | none | 200, `data: character` |
| POST | (base) | editable fields | 201, `data: character` |
| PATCH | `/:id` | editable fields plus `state_version` | 200, `data: character` |
| PUT | `/:id/flags/:key` | `type`, `value`, `player_visible`, `state_version` | 200, `data: character` |
| DELETE | `/:id/flags/:key` | `state_version` | 200, `data: character` |

Mutation bodies must be JSON objects with `Content-Type: application/json`.
Query parameters and unknown body fields are rejected (422). Actor identity and
campaign selection come only from verified scope and the route. There is no
character delete endpoint or generic idempotency contract.

Editable fields are `name`, `discord_user_id`, and `flags`. Creation requires a
name. Omitted ownership means DM-controlled; null or blank ownership unlinks a
character. Discord IDs are decimal strings and use the domain's strict unsigned
64-bit validation. Duplicate ownership within a campaign returns 422 with an
`already_taken` detail. PATCH preserves omitted fields; supplying `flags` replaces
the entire object. PUT/DELETE change one flag and preserve other facts. Clearing
an absent valid key succeeds with a current version.

Example flag PUT body:

```json
{"state_version":1,"type":"integer","value":3,"player_visible":false}
```

Flag values are native JSON booleans, integers or strings, never form strings
coerced to another type. Visibility is mandatory and boolean. Keys, value bounds,
and the 100-flag limit follow the shared [character domain](characters.md).

Every returned character explicitly includes `id`, `campaign_id`, `name`,
`discord_user_id`, `flags`, `state_version`, `inserted_at`, and `updated_at`.
IDs are strings (ownership may be null), versions are integers, and timestamps
are UTC ISO 8601. This is DM-only: hidden flags and their visibility metadata are
included intentionally, unlike the player projection. No associations or quest
internals are serialized. Responses use `Cache-Control: no-store`.

PATCH, PUT and DELETE require the `state_version` from a previous read/response:
missing versions return 428, malformed versions 422, and stale versions 409
`stale_character`. The controller compares the freshly authorized record, then
passes that server-loaded record as `expected_character`; the domain rechecks its
generation under the campaign lock, including concurrent tick/ABA writes. Do not
blindly retry conflicts; reload and review the current state.

All operations call `Characters`; ownership validation, submission invalidation,
fresh DM authorization and campaign configuration checks remain in the domain.
Missing/foreign characters and unauthorized campaigns are concealed as 404
`not_found`. Mutations during a tick lock return 409 `tick_locked`; reads remain
available. Validation failures do not partially update the character.

## Yaak examples

`yaak/characters.json` contains all six endpoints plus intentional 428 missing-version
and 409 stale-version requests. The **Character and flag management** folder is
also saved in the local Async Worlds workspace, with per-resource YAML files in
`yaak/`. To import the portable examples elsewhere:

```sh
yaak import yaak/characters.json --workspace-id YOUR_WORKSPACE_ID
```

Select **Character management examples**. Set `BASE_URL`, `GUILD_ID`, and
`DM_API_TOKEN` locally; the exported token is intentionally blank. Use a development
campaign: create/update/set/clear requests perform real writes, and repeating create
makes another character. Do not run the entire folder blindly.

After creating or retrieving a character, copy `data.id` to `CHARACTER_ID` and
`data.state_version` to `CHARACTER_STATE_VERSION`. Refresh the version from each
successful write before the next edit. `FLAG_KEY` defaults to `debt`. Versions are
inserted as JSON numbers. They are deliberately not auto-refreshed by a response
chain, so a stale edit remains a conflict rather than silently replacing newer state.
