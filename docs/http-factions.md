# HTTP faction management

All routes require the configured DM bearer credential described in
[HTTP API support](http-api.md). `guild_id` is the Discord guild ID, not the
campaign database ID. Browser cookies do not authenticate these routes.

Base path: `/api/campaigns/:guild_id/factions`.

| Method | Path | Result |
| --- | --- | --- |
| GET | base path | 200, campaign factions in creation order |
| GET | `/:id` | 200, one faction |
| POST | base path | 201, created faction |
| PATCH | `/:id` | 200, updated faction |
| DELETE | `/:id` | 200, deleted faction |

POST and PATCH require `Content-Type: application/json` and a flat JSON object
containing only `name` and/or `description`. Name is required for creation and
cannot be cleared (maximum 200 codepoints). Description is optional; null or an
empty string clears it. PATCH preserves omitted fields. DELETE accepts no body
or an empty JSON object. No query parameters are accepted.

Example creation body:

```json
{"name":"The Guild","description":"A trading alliance."}
```

Responses use the standard `data` envelope and `Cache-Control: no-store`.
Each faction contains only `id`, `campaign_id`, `name`, `description`,
`inserted_at`, and `updated_at`. Database IDs are strings; timestamps are ISO 8601
UTC strings. Lists are arrays of these objects. Deletion returns the deleted
record; repeating it returns 404.

Validation failures and unknown fields return 422 `invalid_parameters` with
safe field error codes where available. Missing, malformed, cross-campaign, or
unauthorized resources return 404 `not_found`. Missing or invalid credentials
return 401 `unauthenticated`; non-JSON writes return 415
`unsupported_media_type`. Supplied ownership or actor fields are rejected,
not trusted. Authentication happens before body parsing.

Factions currently have no tick effects and remain writable during tick locks.
There is no version or idempotency precondition: updates are last-write-wins,
creation retries may create additional factions, and deletion is permanent.
Clients should confirm the intended target before deleting and avoid blindly
retrying creation. HTTP reads remain DM-only; verified Discord server members
can read faction names and descriptions through `/faction list` and `/faction show`.

Coverage: `test/async_worlds_web/controllers/faction_controller_test.exs` and
`test/async_worlds_web/faction_live_test.exs`.
