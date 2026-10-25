# Tension HTTP management (ENG-98)

All routes require the configured DM bearer credential and use the Discord guild
ID in `/api/campaigns/:guild_id`. Database resource IDs are decimal strings.
See [authentication](http-api.md), [conventions](http-conventions.md), and
[Tension operations](tension-led-operating-guide.md).

| Method | Campaign-relative path | JSON body | Success |
| --- | --- | --- | --- |
| GET | `/tensions` | none | 200, `data: [tension, ...]` |
| GET | `/tensions/:id` | none | 200, `data: tension` plus detail fields |
| POST | `/tensions` | editable fields | 201, `data: tension` |
| PATCH | `/tensions/:id` | editable fields and `revision` | 200, `data: tension` |
| POST | `/tensions/:id/clocks` | clock editable fields | 201, `data: clock` |
| PATCH | `/clocks/:id/tension` | `tension_id` and `snapshot_token` | 200, `data: clock` |

## Tension requests and responses

Mutations require a JSON object and `Content-Type: application/json`. Query
parameters and unknown fields are rejected. Editable fields are:

- `name`: required on creation, nonblank, at most 200 UTF-8 bytes.
- `description`: optional/nullable, at most 8000 UTF-8 bytes.
- `audience`: `dm` (default) or `public`; null is invalid.

Text must not contain NUL. PATCH preserves omitted fields. Ownership, IDs,
timestamps and `status` are never writable; creation always starts `ongoing`.
Only reviewed tick publication can establish `resolved`. There are no delete,
resolve or reopen endpoints and no new lifecycle rules.

Example POST `/api/campaigns/123/tensions` body:

```json
{"name":"Battle at the crossing","description":"The river is contested","audience":"dm"}
```

Example creation response (201):

```json
{
  "data": {
    "id": "12",
    "campaign_id": "1",
    "name": "Battle at the crossing",
    "description": "The river is contested",
    "audience": "dm",
    "status": "ongoing",
    "revision": 1,
    "inserted_at": "2026-10-25T15:00:00Z",
    "updated_at": "2026-10-25T15:00:00Z"
  }
}
```

List, create and edit return exactly these tension fields. Lists are unpaginated,
ordered by status then ascending ID. GET detail additionally includes:

```json
{
  "clock_ids": ["31", "32"],
  "discussion": {"status":"ready","guild_id":"123","thread_id":"987"}
}
```

`clock_ids` includes all associated clocks, including hidden ones, ordered by ID.
Fetch full clock resources and mutation tokens from the existing DM
`/clocks/:id` endpoint. `discussion` is null if absent; otherwise only `status`,
`guild_id` and nullable `thread_id` are exposed. Status can be `pending`,
`creating`, `ready`, `ambiguous` or `blocked`. A bound discussion can be opened at
`https://discord.com/channels/<guild_id>/<thread_id>`. Internal creation claims,
generation, recovery audits and saved outgoing prose are not serialized.
These routes do not send discussion messages or recover failed thread creation.

Example PATCH `/api/campaigns/123/tensions/12` body:

```json
{"revision":1,"description":"The crossing holds"}
```

Use the revision from the inspected read or previous successful write. Successful
edits return the incremented revision (2 in this example); publication also
advances it. Missing revision returns 428 `precondition_required`, malformed
revision returns 422 `invalid_parameters`, and a stale revision returns 409
`stale_tension`. The adapter compares the revision against a freshly authorized
record and passes that full server-loaded record to the existing domain operation,
which rechecks it under the campaign lock. There is no blind latest-state retry.

## Clocks and associations

Additional endpoints are needed to match the existing UI: atomic nested clock
creation and snapshot-guarded attachment/detachment. Ordinary clock PATCH now
accepts `mode`, `influences`, `empty_description` and `full_description` in addition
to its existing fields. Mode is `countdown` (default) or `tug_of_war`; optional
descriptive text has the same 8000-byte, UTF-8/no-NUL rules. Mode is descriptive,
not a new lifecycle or automatic resolution mechanism. See [HTTP clocks](http-clocks.md)
for triggers, fill clamping, snapshots, adjustment, resets and racing controls.

Example POST `/api/campaigns/123/tensions/12/clocks` body:

```json
{
  "name":"Battle balance",
  "segments":8,
  "filled":3,
  "mode":"tug_of_war",
  "influences":"River traffic",
  "empty_description":"Retreat",
  "full_description":"Advance"
}
```

This atomically creates and associates the clock, defaulting visibility to
`hidden` (unlike standalone clock creation's `public` default). Explicit
visibility is respected. It returns the full clock resource including
`tension_id`, integer `association_revision`, descriptive fields and the signed
`snapshot_token`. Invalid input or a missing/foreign tension leaves no clock or
audit behind. Clock edits use the existing `PATCH /clocks/:id` route.

Example PATCH `/api/campaigns/123/clocks/31/tension` body:

```json
{"tension_id":"12","snapshot_token":"<token from inspected clock>"}
```

For detachment, explicitly send `"tension_id": null`; omitting the field is a
422, not an implicit detach. The target and clock must belong to the campaign.
Missing tokens return 428; stale, tampered, expired or misbound tokens return 409
`stale_clock`. Each successful association/detachment increments
`association_revision` and returns a fresh token; association never changes clock
visibility. Completed clocks return 409 `completed`. All operations reuse
`DM.Tensions`/`DM.Clocks`; association/creation audits use `dm:http:<verified DM>`.

## Privacy, locks and errors

Every endpoint is DM-only, including when `audience` is public. Private tensions,
prose and hidden clocks are intentionally visible only to the campaign DM. Public
audience opts prose into the existing Discord/publication flow; it does not grant
HTTP access. Returning to DM-only does not erase previously published history.
There is no player projection or player credential accepted by these routes.

Missing/invalid bearer credentials return 401. Unauthorized/missing campaigns and
missing/foreign resources are concealed as 404 `not_found`. All management writes
retain existing 409 `tick_locked` behavior during resolution/review; reads remain
available. Nothing here bypasses publication or fires clock triggers. Validation
returns 422 `invalid_parameters` with bounded field/code details; unsupported
content types return 415. Responses use `data` or the standard `error.code`
envelope and `Cache-Control: no-store`, for example:

```json
{"error":{"code":"stale_tension"}}
```

Run `mix test test/async_worlds_web/controllers/tension_controller_test.exs` for
the transport contract and `mix precommit` for the complete suite.
