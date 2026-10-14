# HTTP tick lifecycle and readiness (ENG-57)

All routes require [DM bearer authentication](http-api.md), scoped by Discord
`guild_id`. Responses follow [HTTP conventions](http-conventions.md): `data`
envelopes, string resource IDs, integer tick numbers/counts, ISO 8601 UTC
timestamps and `Cache-Control: no-store`.

Base: `/api/campaigns/:guild_id/ticks`

| Method | Path | Result |
| --- | --- | --- |
| GET | `/status` | 200 active tick, else latest published tick, else `null` |
| POST | `/open` | 201 newly opened tick |
| POST | `/:id/close` | 202 closed tick after durable resolution enqueue |
| GET | `/:id/readiness` | 200 readiness summary |
| GET | `/:id/readiness/roster` | 200 summary plus character rows |
| POST | `/remind` | 202 reminder intents for missing active-tick submissions |

No query parameters are accepted. POST bodies must be JSON objects with no
fields (`{}`) and `Content-Type: application/json`. Do not supply actor IDs.
Tick IDs in paths are database IDs, not tick numbers. Close targets the explicit
ID; it never implicitly selects a newer active tick on a retry.

## Lifecycle

Tick projections contain only `id`, `campaign_id`, `number`, `status`,
`opened_at`, `closed_at`, `reviewed_at` and `published_at`. Absent timestamps
are null. Status is `open`, `resolving`, `in_review` or `published`.

Open invokes the shared domain operation, committing announcements and private
prompts with the tick. An already active tick returns 409 `active_tick`.
Close freezes world/quest inputs, locks management, and queues resolution in
one transaction. Missing submissions are informational and do **not** block
close. Repeated closes while resolving/in review return 202 with the existing
tick, without creating another snapshot or resolution job. Closing a published
tick returns 409 `invalid_transition`. HTTP never exposes raw snapshots, drafts
or worker errors through these endpoints; it does not run resolution itself.

## Readiness

Summary data contains `tick_id`, `tick_number`, `frozen` and `counts` with
integer `active`, `submitted`, `missing` totals. Rosters add `rows`, including
every character, not just players with active quests. Each row contains:

- `character_id`, `name`, `discord_user_id` (null for DM-controlled subjects)
- `unassigned`, `invalidated` booleans
- `quest_name`, `node_id` (null without an active quest)
- `state`: `submitted`, `missing` or `no_active_quest`

Open ticks report live inputs. All closed/published ticks report frozen snapshot
inputs only, including character names/owners. Counts match shared domain
readiness. `invalidated` marks an earlier choice that became stale/ineligible;
`unassigned` distinguishes DM-controlled subjects from missing player choices.
There are no flags, quest definitions, choice identities or delivery guards in
these projections. Malformed, foreign and missing tick IDs return 404
`not_found`.

## Reminders

Send exactly one `Idempotency-Key` header: a nonblank UTF-8 string of 1–200 bytes,
without NUL. Missing keys return 428 `precondition_required`; invalid keys return
422 `invalid_idempotency_key`. Discord interaction IDs remain valid keys; HTTP
keys need not be snowflakes.

The response is `{"data":{"missing":2}}`. This counts missing subjects, **not**
newly created messages (a subject can route to multiple recipients). The shared
outbox deduplicates reminder intents per tick/character/recipient, regardless of
request key. Repeated or different keys do not resend existing reminders,
replace delivery status, or retry failed/ambiguous sends. This is not a generic
key-to-response replay cache: counts reflect current missing subjects.

The operation selects and validates the active tick under the authorization
lock. No active tick returns 404 `no_tick`; a closed active tick returns 409
`tick_closed`. Submission/progression state is not changed. Delivery retains
its existing fresh-state guards, so later submission, ownership changes or
closing can suppress queued reminders. No network I/O happens in the request.
