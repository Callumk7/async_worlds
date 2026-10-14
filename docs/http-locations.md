# HTTP location management

All routes use the configured DM bearer credential described in
[HTTP API support](http-api.md). `guild_id` is the Discord guild ID, not the
campaign database ID. Browser cookies do not authenticate these routes.

Base path: `/api/campaigns/:guild_id/locations`.

| Method | Path | Result |
| --- | --- | --- |
| GET | base path | 200, campaign locations in creation order |
| GET | `/:id` | 200, one location |
| POST | base path | 201, created location |
| PATCH | `/:id` | 200, updated location |
| DELETE | `/:id` | 200, deleted location |

POST and PATCH require `Content-Type: application/json` and a flat object with
only `name` and/or `description`. Name is required for creation and cannot be
cleared (maximum 200 codepoints). Description is optional; null or an empty string
clears it. PATCH preserves omitted fields. DELETE accepts no body or an empty
JSON object. No query parameters are accepted.

Example creation body:

```json
{"name":"Harbour","description":"The city's docks."}
```

Responses use the standard `data` envelope and `Cache-Control: no-store`. Each
location projects only `id`, `campaign_id`, `name`, `description`, `inserted_at`,
and `updated_at`. IDs are strings and timestamps are ISO 8601 UTC strings. Lists
return arrays; deletion returns the deleted record, with subsequent reads/deletes
returning 404.

Validation failures and unknown fields return 422 `invalid_parameters`, with
safe field error codes where available. Missing, malformed, cross-campaign, or
unauthorized resources return 404 `not_found`. Missing/invalid credentials return
401 `unauthenticated`, and non-JSON writes return 415 `unsupported_media_type`.
Authentication runs before body parsing. Actor and ownership fields are rejected.

Locations have no tick effects and remain writable during tick locks. There are
no version or idempotency preconditions: updates are last-write-wins, creation
retries may create duplicates, and deletion is permanent. Confirm the intended
target before deleting and avoid blindly retrying creation.

HTTP reads remain DM-only. Verified Discord server members can read location
names and descriptions through `/location list` and `/location show`.

Coverage: `test/async_worlds_web/controllers/location_controller_test.exs`,
`test/async_worlds_web/location_live_test.exs`, and
`test/async_worlds/discord/location_commands_test.exs`.
