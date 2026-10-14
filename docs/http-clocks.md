# Clock HTTP management (ENG-54)

All routes use `/api/campaigns/:guild_id/clocks` as their base and require the
configured DM bearer credential. Guild IDs are Discord IDs; clock IDs are scoped
database IDs. See [authentication](http-api.md), [conventions](http-conventions.md),
and the shared [clock domain](clock-management.md).

| Method | Relative path | JSON body | Success |
| --- | --- | --- | --- |
| GET | (base) | none | 200, `data: [...]`, ascending clock ID |
| GET | `/:id` | none | 200, `data: clock` |
| POST | (base) | editable fields | 201, `data: clock` |
| PATCH | `/:id` | editable fields, `snapshot_token` | 200, `data: clock` |
| POST | `/:id/adjust` | integer `delta`, `snapshot_token` | 200, `data: clock` |
| POST | `/:id/pause` | `snapshot_token` | 200, `data: clock` |
| POST | `/:id/resume` | `snapshot_token` | 200, `data: clock` |
| POST | `/:id/reset` | `snapshot_token`, partner token if paired | 200, `data: clock` |
| POST | `/:id/pair` | `partner_id`, both snapshot tokens | 200, `data: [clock, partner]` |
| POST | `/:id/unpair` | `snapshot_token`, partner token if paired | 200, `data: [...]` of affected clocks |

Mutations require JSON objects and `Content-Type: application/json`. Query
parameters and unknown fields are rejected. Editable fields are `name`,
`segments`, `filled`, `visibility`, `background_rate`, `paused`, and `triggers`.
Creation requires name and size; sizes are 4/6/8, visibility is public/known/hidden.
The shared domain clamps fill to 0..size; resizing clamps existing fill. Signed
background rates must fit the database's 32-bit integer. PATCH preserves omitted
fields and replaces the whole ordered trigger list when supplied. Pause/resume
are audited edits, not changes to fill. Adjustment takes a native JSON integer.

Triggers retain shared type/payload/reference validation:

```json
{
  "name": "Storm",
  "segments": 6,
  "visibility": "hidden",
  "triggers": [
    {"type":"notify_dm","text":"Storm ready"},
    {"type":"world_news","text":"Storm clouds gather"},
    {"type":"start_clock","clock_id":"42"},
    {"type":"set_flag","character_id":"7","key":"debt","flag":{"type":"integer","value":3,"player_visible":false}},
    {"type":"unlock_quest","character_id":"7","quest_id":"12"}
  ]
}
```

References must belong to this campaign; a clock cannot start itself. Native flag
values and explicit visibility are required. Saving configuration does not run
triggers or send messages. Bad trigger containers, payloads, foreign references,
NUL-containing names/text, and out-of-range rates return 422 without partial writes.

## Snapshots and racing

Every clock response explicitly includes `id`, `campaign_id`, `name`, `segments`,
`filled`, `visibility`, `background_rate`, `paused`, `completed`, `racing_group`,
ordered `triggers`, `inserted_at`, `updated_at`, and `snapshot_token`. IDs (including
trigger target IDs) are decimal strings, groups are UUIDs, timestamps are UTC ISO
8601, and counts/rates are integers. This is DM-only: hidden clocks and their full
state are intentionally included. No schemas, associations or audit snapshots are
serialized. Responses use `Cache-Control: no-store`.

All existing-clock mutations require the signed `snapshot_token` from a read or
previous write. Missing tokens return 428; invalid, expired, misbound or changed
snapshots return 409 `stale_clock`. Tokens bind clock ID, full loaded state,
campaign configuration and verified actor and expire after 24 hours. Reload and
review conflicts; no automatic retry or latest-state substitution occurs.

Pairing additionally requires `partner_id` and `partner_snapshot_token`. Reset
and unpair affect both members of an existing race, so they also require the
current `partner_snapshot_token`; no partner ID is accepted for those operations.
For unpaired clocks, omit the partner token. Reset clears fill/completion on both
members while preserving pause/configuration; it returns the requested clock,
so reread its partner before further changes. Unpair returns both affected clocks.
Self-pairing, existing membership and completed members remain domain errors.

The transport verifies tokens against freshly actor-authorized records and passes
only those server-loaded records to the domain. The domain compares every affected
member (and race membership) under its campaign lock before any write/audit. The
optional expected-record arguments are additive; trusted existing callers retain
intentional current-state operations. There is no database generation for clocks:
these tokens preserve the existing full-record comparison, not a new ABA guarantee.

All endpoints use `DM.Clocks`, deriving audit source `dm:http:<verified actor>`.
Audits retain the active tick attribution; callers cannot supply source or actor.
Missing/foreign resources and unauthorized campaigns are concealed as 404.
Tick locks reject all management writes with 409 `tick_locked`, but allow reads.
Completed clocks reject edits/adjustments until reset. Reaching full alone never
completes or executes triggers. Completion, unlocking management locks and raw
membership edits are not HTTP management endpoints.

## Yaak examples

`yaak/clocks.json` provides the endpoints, a partner creation example, and missing
or invalid snapshot-token failures. Import with:

```sh
yaak import yaak/clocks.json --workspace-id YOUR_WORKSPACE_ID
```

Select **Clock management examples** and configure `BASE_URL`, `GUILD_ID` and
`DM_API_TOKEN` locally. Tokens/credentials in the export are intentionally blank.
Copy `data.id` and `data.snapshot_token` from create/get responses into `CLOCK_ID`
and `CLOCK_SNAPSHOT_TOKEN`; use `PARTNER_CLOCK_ID` and `PARTNER_SNAPSHOT_TOKEN` for
the second clock. Refresh tokens from successful responses or GET before the next
write; templates deliberately do not fetch the latest state automatically.

Use a development campaign and send requests individually: creation makes a new
clock each time, and adjustment/reset/pairing change real state. For paired reset
add `"partner_snapshot_token": "${[ PARTNER_SNAPSHOT_TOKEN ]}"` to the example
body. The unpair example includes that field; remove it for an unpaired clock.
Do not run the folder blindly as a write suite.
