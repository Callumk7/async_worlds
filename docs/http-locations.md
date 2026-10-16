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
| GET | `/roots` | 200, root locations in ascending ID order |
| GET | `/:id/children` | 200, immediate children in ascending ID order |
| GET | `/:id/breadcrumbs` | 200, root-to-location path including the location |
| PATCH | `/:id/parent` | 200, location with updated parent |

POST and PATCH require `Content-Type: application/json` and a flat object with
only `name`, `description` and/or `kind`. Name is required for creation and cannot
be cleared (maximum 200 codepoints). Description is optional; null or an empty
string clears it. Kind is optional free text; blank/null clears it. Text must be
valid UTF-8 without NUL. PATCH preserves omitted fields. Parent IDs are not
accepted in metadata POST/PATCH: use the separate parent operation below. DELETE
accepts no body or an empty JSON object. No query parameters are accepted.

Example creation body:

```json
{"name":"Harbour","description":"The city's docks."}
```

Responses use the standard `data` envelope and `Cache-Control: no-store`. Each
location projects only `id`, `campaign_id`, `name`, `description`, `kind`,
`parent_id`, `inserted_at`, and `updated_at`. `parent_id` and `kind` are nullable.
IDs are strings and timestamps are ISO 8601 UTC strings. Lists return arrays;
deletion returns the deleted record, with subsequent reads/deletes
returning 404.

Validation failures and unknown fields return 422 `invalid_parameters`, with
safe field error codes where available. Missing, malformed, cross-campaign, or
unauthorized resources return 404 `not_found`. Missing/invalid credentials return
401 `unauthenticated`, and non-JSON writes return 415 `unsupported_media_type`.
Authentication runs before body parsing. Actor and ownership fields are rejected.

## Parent changes (ENG-87)

`PATCH /:id/parent` requires exactly `{"parent_id":"123"}` to set/reparent, or
`{"parent_id":null}` to clear. An omitted field returns 422 `invalid_parameters`;
malformed, missing or foreign endpoint IDs return 404 `not_found`. Numeric IDs
are also accepted. Self-parenting and indirect cycles return 409 `location_cycle`.
Traversal is bounded to 100 nodes; excessive depth returns 409 `hierarchy_too_deep`.
Queries validate their endpoint even if the resulting child list would be empty.

All hierarchy reads and writes freshly authorize the authenticated DM through the
shared campaign-locked context. Parent changes atomically retain link history
with the current open tick, otherwise the actual next tick (even before it exists).
Opening that tick does not recalculate old associations. Repeating the same parent
or clearing an already-root location is a no-op with no additional history. Kind
edits do not retain link history. There are no history/audit HTTP routes.

Locations have no gameplay effects and remain writable during tick locks. There are
no version or idempotency preconditions: updates are last-write-wins, creation
retries may create duplicates, and deletion is permanent. Confirm the intended
target before deleting and avoid blindly retrying creation. Deleting a location
with a parent or children returns 409 `location_linked`; clear those links through
`PATCH /:id/parent` first, including for each child. No links are silently removed;
retained history survives endpoint deletion.

HTTP reads remain DM-only. Verified Discord server members can read location
names and descriptions through `/location list` and `/location show`.

Coverage: `test/async_worlds_web/controllers/world_relationship_controller_test.exs`,
`test/async_worlds_web/controllers/location_controller_test.exs`,
`test/async_worlds_web/location_live_test.exs`, and
`test/async_worlds/discord/location_commands_test.exs`.
