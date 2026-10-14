# Quest JSON import (ENG-15)

Import is a **trusted DM/operator** tool, not a player upload endpoint. The Mix
task and authenticated HTTP endpoint share
`AsyncWorlds.Quests.import_json(campaign, dm_id, json, clock_refs: bindings)`.
It re-fetches the campaign and authorizes its current DM while holding the
campaign row lock. Supplying an old campaign struct cannot restore revoked
access. It never assigns, swaps, moves, or publishes a character.

## HTTP import (ENG-29)

`POST /api/campaigns/:guild_id/quests/import` accepts the **original version-1
JSON document** as the body, with `Content-Type: application/json` and
`Authorization: Bearer <token>`. `guild_id` is the Discord guild ID, not the
internal database campaign ID. No multipart upload or extra JSON wrapper is used.
The maximum body size is **1 MiB (1,048,576 bytes)**, including whitespace.

Configure a trusted operator credential on the server before starting it:

```sh
# Generate a random credential locally; never commit it.
export DM_API_TOKEN="$(openssl rand -hex 32)"
export DM_API_DM_USER_ID="456"
mix phx.server
```

The token must be at least 32 bytes; use a cryptographically random value.
Both settings are required together. Without them the endpoint fails closed.
The token authenticates the configured Discord DM identity, not a caller-supplied
ID. Current campaign ownership is rechecked on every request and again under the
import transaction lock. A token can access only campaigns currently owned by
that identity. Browser cookies do not authenticate this endpoint; it uses no
cookie/session authentication and needs no CSRF token. Use HTTPS outside localhost.
Rotate/revoke the credential by changing/removing the settings and restarting.
This is a single operator credential, not a public token issuance service.
Authentication is shared across all HTTP APIs; see [HTTP API authentication](http-api.md).

Optional clock bindings are query parameters such as
`?clock_refs[alarm]=1&clock_refs[danger]=2`. Values must be positive integer IDs;
clocks must exist in the selected campaign. All other query parameters are
rejected. The body remains strict: adding `clock_refs` or `dm_user_id` to it
is not supported.

Successful imports return **200**, including mixed created/appended/unchanged
batches, with results in input order:

```json
{
  "data": [
    {
      "action": "created",
      "quest_id": 1,
      "revision_id": 1,
      "revision_number": 1
    }
  ]
}
```

Failures return `{"error":{"code":"..."}}`, optionally with `details`:

| Status | Code                     | Meaning                                                         |
| ------ | ------------------------ | --------------------------------------------------------------- |
| 400    | `invalid_json`           | JSON syntax error; details include `$` and decoder message      |
| 400    | `body_read_failed`       | Request body could not be read                                  |
| 401    | `unauthenticated`        | Missing/invalid token or API credential not configured          |
| 404    | `not_found`              | Missing, invalid or unauthorized campaign (same response)       |
| 413    | `payload_too_large`      | Body exceeds 1 MiB                                              |
| 415    | `unsupported_media_type` | Content-Type is not application/json                            |
| 422    | `invalid_document`       | Strict document validation failed; details include path/message |
| 422    | `invalid_clock_refs`     | Query parameters/bindings have an invalid shape or value        |

Duplicate JSON keys are rejected with 422, not silently overwritten. Authentication
and campaign authorization happen before reading or decoding the body. A bad
clock reference produces an `invalid_document` error at its document path.

### Yaak examples

The existing **Async Worlds** workspace has a **Quest JSON imports** folder with
four requests: a minimal quest, a multi-quest/2d6 batch, Harbor with an `alarm`
binding, and an intentional 422 validation failure. Select **Quest import examples**
and set `BASE_URL`, `GUILD_ID`, and `ALARM_CLOCK_ID` to your local values. Keep
`DM_API_TOKEN` in a **private local environment** (copy the examples environment and
mark it private before filling in credentials). The checked-in examples contain
no token. Do not export real credentials or commit secret environment files.

To load the portable examples into another existing workspace:

```sh
yaak import yaak/quest-import.json --workspace-id YOUR_WORKSPACE_ID
```

The import command copies resources; do not repeatedly import it into the same
workspace. Send individual requests when checking outcomes; the fourth request
is deliberately invalid and should return 422. Valid requests persist campaign
content, so use a disposable/local campaign first. Neither import nor these
requests assigns or publishes quests.

## Bootstrap without SQL

Run from the repository with dependencies installed and PostgreSQL configured
(`PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD`; see README for normal setup). No
Discord token/network is needed; leave the bot disabled for local bootstrap.
Replace the example Discord IDs with your campaign's IDs:

```sh
mix ecto.create
mix ecto.migrate
mix campaign.setup --guild-id 123 --dm-user-id 456 --public-channel-id 789
mix clock.create --guild-id 123 --dm-user-id 456 --name "Harbor alarm" --segments 6 --visibility hidden
# The preceding command prints the actual clock ID. Substitute it for 1 below:
mix quest.import --guild-id 123 --dm-user-id 456 --file priv/quests/harbor.json --clock alarm=1
# Repeat the SAME import: each quest reports `unchanged`, with the same revision ID.
```

`clock.create` is deliberately **not idempotent**; run it once, keep its ID, and
reuse it. It uses `Quests.create_clock/3`, a freshly authorized wrapper over the
existing audited, campaign-serialized `Clocks.create_clock/3`. Clock creation
is rejected during resolving/review. The trusted bootstrap wrapper requires a
nonempty name of at most 200 UTF-8 bytes and rejects NUL before persistence
(`:invalid_clock_name`). A source label alone in the lower-level
Clocks API is not authorization; operator callers must use the wrapper.
`quest.import` accepts repeated `--clock alias=id` arguments; duplicate aliases
are rejected. Bindings refer to existing clocks only and never create clocks.
An integer `clock_id` in JSON may be used instead. In either case the clock must
belong to the selected campaign. Aliases are converted to integer IDs before
validation/persistence; the immutable revision contains no unresolved aliases.
A clock in another campaign (or a missing/unbound clock) gets the same error.

Manage characters and assign the printed revision ID through the existing
`/characters` and `/quests` DM pages (or shared `Characters.create_character/3`
and `Quests.assign/4` operations). See [quest-operations.md](quest-operations.md).
The fixture offers a fixed entry/exit, a cyclic retreat/partial result, two
explicit endings, typed flags, a clock threshold, clamped clock deltas, a
2d6 roll, and ordered critical bonus effects. Normal tests execute the fixture
through import, assignment, submission, close/freeze and draft resolution,
plus controlled pure cyclic/rolled/ending transitions. Existing quest
publication uses ENG-20's audited review boundary; import cannot repin or
rewrite a frozen or published turn. See [quest-review.md](quest-review.md).

## Version 1 contract

Root is exactly `{"version": 1, "quests": [...]}` (nonempty quests). Every quest
is exactly `{"content_id": "stable-id", "name": "Display name", "definition": ...}`.
`content_id` is unique in the document and within the campaign; names are
nonempty, at most 200 bytes. Definition is exactly `start_node`, `nodes`.

All objects are strict: unknown/missing fields, duplicate JSON object keys,
duplicate IDs, incorrect types and unsupported variants fail. IDs are 1–100
ASCII letters/digits/underscore/hyphen. Text/labels/outcome text are nonempty
valid strings, at most 8000 bytes, with no NUL. Array order is retained.

- Node: `id`, `text`, `ending` (boolean), `choices` (array). Node IDs are unique
  per quest. Endings require no choices; non-endings require at least one.
- Choice: `id`, `label`, `eligibility` (`hidden`/`disabled`), `conditions` (ANDed
  array), `mode`, `outcomes`. Choice IDs are unique across all nodes of a quest.
- Fixed: `mode: "fixed"`, `outcomes` exactly `fixed`; no dice/critical fields.
- Rolled: `mode: "rolled"`, integer `dice` 1–3, `critical_effects` array,
  `outcomes` exactly `success`, `partial`, `failure`.
- Outcome: `text`, `next_node`, `effects` array. Start/next node references are
  **local to this quest definition**, never another quest/revision/campaign.
  Cycles are allowed; explicit endings are not inferred from reachability.
- Condition `clock_threshold`: `type`, `clock_id` (integer ID or bound alias),
  `operator` (`gte`/`lte`), integer `value` between zero and current clock size.
- Condition `character_flag`: `type`, `key`, `flag_type`
  (`boolean`/`integer`/`string`), `value` matching that type.
- Effect `clock_delta`: `type`, `clock_id`, integer `delta` within ±1,000,000.
- Effect `set_flag`: `type`, `key`, `flag` exactly `type`, `value`,
  `player_visible` (boolean). Effect `clear_flag`: `type`, `key`.

Flag keys/values follow [characters.md](characters.md) and existing ENG-13
validation. Flags target only the acting character. No resource conditions,
effects, declarations, grants or other resource mechanics are accepted.
See [quest-domain.md](quest-domain.md) for execution semantics/privacy.

## Atomicity and revision semantics

The whole document is decoded and validated before writes, inside one freshly
authorized transaction. Any error leaves **all** quest/revision/node rows
unchanged, including earlier entries or renames. Writes serialize on the same
campaign lock as authoring and tick close. The result is
`{:ok, [%{action: :created | :appended | :unchanged, revision: revision}, ...]}`.

A new `content_id` creates quest + revision 1. A repeat whose resolved
**definition and name equal the latest** stored definition/name returns the
same revision with `:unchanged`, inserting nothing. JSON whitespace/object
key order do not matter; array order does. A changed definition (or name)
appends a revision, preserving the stable quest row; it never rewrites old
revisions or node indexes. Reimporting an older definition after a newer one
appends again, rather than selecting the historical revision. No removals are
performed for quests omitted from the document. The name is a current quest
label, not a historical revision field. All imports validate references and
thresholds against **current** campaign clocks, including repeat imports.

Authoring/import may append during resolving/review, just like existing quest
authoring. Pinned assignments and already-frozen tick inputs are unchanged;
new revisions become available only for intentional later assignment/swap.
No revision or live progression is deleted, updated or silently repinned.

Failures return `{:error, [%{path: "$.quests[0].definition.nodes[1]...", message: ...}]}`
(first structural/content error, zero-based array indexes). JSON syntax errors
report `$` and the decoder's byte-position detail. Authorization/campaign
failures retain shared domain atoms such as `:unauthorized`, `:invalid_id`,
`:not_found`. The task prints the path and exits nonzero; never a success with
partial content.

## Offline regression commands

```sh
mix test test/async_worlds/quest_import_test.exs
mix precommit
```

Use an isolated PostgreSQL database for tests. The normal suite uses fake
Discord delivery and manual Oban jobs; it does not make Discord requests.
