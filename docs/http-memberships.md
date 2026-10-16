# HTTP faction memberships (ENG-87)

All routes require the configured DM bearer credential described in
[HTTP API support](http-api.md). `guild_id` is the Discord guild ID, not the
campaign database ID. Browser cookies and request-supplied actor IDs do not
authenticate requests. These are DM-only descriptive relationships, not player
endpoints or permission grants.

Base path: `/api/campaigns/:guild_id`.

| Method | Path relative to base | Result |
| --- | --- | --- |
| GET | `/factions/:id/memberships` | 200, current faction memberships |
| GET | `/characters/:id/memberships` | 200, current character affiliations |
| POST | `/memberships` | 201, joined membership |
| PATCH | `/memberships/:id` | 200, role-edited membership |
| DELETE | `/memberships/:id` | 200, removed membership |

Lists are ordered by ascending membership ID. Both list endpoints validate the
selected entity even when there are no current memberships. No query parameters
are accepted.

POST requires a flat JSON object with `character_id` and `faction_id`, plus an
optional `role`:

```json
{"character_id":"123","faction_id":"456","role":"Scout"}
```

PATCH accepts only `role`. Omission preserves it; null or blank clears it. Role
is free text, at most 200 Unicode codepoints, valid UTF-8 without NUL. Endpoints
cannot be reassigned by PATCH: leave and join instead. DELETE accepts no body or
an empty JSON object. Writes with bodies require `Content-Type: application/json`.
Unknown fields, including actor, ownership, tick, primary-faction and version
fields, return 422 `invalid_parameters`.

Responses use `{"data":...}` and `Cache-Control: no-store`. Each membership
projects only `id`, `campaign_id`, `character_id`, `faction_id`, `role`,
`inserted_at` and `updated_at`. IDs are decimal strings, role is nullable, and
timestamps are ISO 8601 UTC strings. Preloaded character/faction records, player
identities, flags, history and internal metadata are never serialized. Lists
return arrays. DELETE returns the removed record, not an archive.

## Errors and retries

Missing/invalid credentials return 401 `unauthenticated` before body parsing.
Missing, malformed, out-of-range or foreign targets (including absent join
endpoints), and loss of DM access return 404 `not_found`. Duplicate current
character/faction joins and invalid roles return 422 `invalid_parameters`.
Safe validation details expose only allowed role field names and fixed codes,
not constraint names or submitted values. Non-JSON bodies return 415
`unsupported_media_type`. A configuration change after request authorization
can return 409 `stale_campaign`; re-read after checking campaign configuration.

There are no new mandatory version/precondition inputs, idempotency headers or
automatic retries. Role edits are last-write-wins. An unchanged role is a successful
no-op and retains no history. Retrying a join of a current pair fails as a duplicate;
repeating leave or editing a removed membership returns 404. Rejoining after leave
creates a new current membership ID.

## Shared transaction and reference safety

All operations call [Memberships](memberships.md), which freshly authorizes the
verified DM under the campaign lock and validates campaign-scoped targets. Join,
role edit and leave atomically retain their before/after link state with the
current open tick, or the actual next tick if none is open. That tick need not
exist yet; opening it preserves the selected association. Failed history writes
roll back current state too. Leaving/rejoining never erases earlier history.
There are no history/audit routes.

Descriptive memberships remain editable during gameplay tick locks and do not
change character state versions, ownership, quest inputs, publications, jobs or
deliveries. Existing member-facing faction, character and Discord projections
remain unchanged and expose no relationship data.

Faction DELETE returns 409 `faction_has_memberships` while current memberships
reference it. Explicitly leave those memberships before retrying deletion; no
silent cascade bypasses retained history. Character deletion has no supported
HTTP operation. See [HTTP locations](http-locations.md) for location reference
safety and hierarchy operations.

Coverage: `test/async_worlds_web/controllers/world_relationship_controller_test.exs`
and `test/async_worlds_web/controllers/faction_controller_test.exs`.
