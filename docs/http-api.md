# HTTP API support

All `/api` requests require a configured DM bearer credential. This is a single
manually provisioned operator credential, not a player API or key-management service.

```sh
export DM_API_TOKEN="$(openssl rand -hex 32)"
export DM_API_DM_USER_ID="456"
mix phx.server
```

The token must be at least 32 bytes; generate it randomly and keep it out of source
control and logs. The identity must be a valid Discord user ID. Settings are
optional, but must be supplied together; without credentials API access fails
closed. Normal tests ignore these environment variables.

Send `Authorization: Bearer <token>`. Browser cookies do not authenticate API
requests. Use HTTPS outside localhost. Rotate or revoke credentials by changing
or removing the environment settings and restarting the application. There is
no web-based key display, issuance or per-key permissions yet.

Character and flag routes are documented in [HTTP character management](http-characters.md).
Clock routes are documented in [HTTP clock management](http-clocks.md).
Faction CRUD routes are documented in [HTTP factions](http-factions.md).
Tick lifecycle, readiness and reminder routes are documented in [HTTP ticks](http-ticks.md).
Draft review, previews, audited edits and publication are documented in [HTTP tick review](http-tick-review.md).
Published ticks and personal results/submissions are documented in [HTTP history](http-history.md).
Delivery inspection and retries are documented in [HTTP deliveries](http-deliveries.md).
Journal creation, browsing and deletion are documented in [HTTP journals](http-journals.md).
Quest library and authoring routes are documented in [HTTP quests](http-quests.md).
Assignment and intervention routes are documented in [HTTP quest interventions](http-quest-interventions.md).

See [HTTP conventions](http-conventions.md) for response envelopes, safe error
codes, pagination and required concurrency/idempotency inputs.

## Controller contract

`AsyncWorldsWeb.ApiAuth` runs in the endpoint before body parsing for every
`/api/...` path, independently of HTTP method. Token comparison uses fixed-size
hashes and constant-time comparison. Multiple Authorization headers are rejected.

Campaign routes must use `/api/campaigns/:guild_id/...`, where `guild_id` is the
Discord guild ID, not the internal database ID. Current campaign ownership is
checked on every request. The authenticated scope is:

- `conn.assigns.current_scope.discord_user_id`: verified configured DM identity.
- `conn.assigns.current_scope.campaign`: freshly authorized campaign.

Other API paths receive the verified identity with `campaign: nil`; controllers
must authorize any selected campaign with `Campaigns.authorize_dm/2`. Never use
request-supplied actor IDs as credentials. Domain transaction authorization and
concurrency checks still apply; the request scope is not a replacement for them.
For tick, clock and delivery operations, pass this scope to the actor-aware
`AsyncWorlds.DM` modules; see [shared DM boundaries](dm-domain.md).

Missing/invalid credentials return **401** with `WWW-Authenticate: Bearer` and
`{"error":{"code":"unauthenticated"}}`. Missing, malformed or unauthorized
campaigns return the same **404** `{"error":{"code":"not_found"}}` response.
These checks happen before JSON parsing, including malformed request bodies.
Browser/LiveView authentication is unchanged.

Quest import uses this shared scope while retaining its bounded raw-body reader
and duplicate-key validation. See [quest import](quest-import.md) for payloads.

## Reusable examples and verification

Import `yaak/http-operations.json` into Yaak and select **HTTP operations examples**.
It adds 30 requests for tick lifecycle/review/publication, published and personal
history, delivery inspection/retry and journals. The token value is deliberately
blank; fill it locally, never commit it. Existing `yaak/characters.json`,
`clocks.json`, `quest-authoring.json`, `quest-interventions.json` and
`quest-import.json` cover the earlier resources.

Read and mutation folders are separated. **Do not send the whole workspace or
mutation folders as a batch**: opening/closing/publishing, rerolling, retrying and
deleting have real effects. Use a disposable campaign and send writes individually.
Copy draft IDs, quest input identities, die old values, delivery generations and
journal deletion tokens from reads. Numeric preconditions in sample bodies are
illustrative integers and must be replaced with the inspected values. Do not
chain mutations to automatically refreshed reads: that defeats stale-edit safety.

A safe manual sequence is:

1. Read tick status and readiness. Open/close only when appropriate.
2. Wait for resolution, read the review, and copy its current draft UUID.
3. Preview that exact UUID. Make a reasoned edit, then copy the returned new UUID.
4. Preview again and explicitly approve publication. An old UUID must fail with
   `409 stale_draft`, never publish newer content implicitly.
5. Browse saved tick/character history. Delivery failures do not change saved results.
6. Inspect a failed delivery and copy its generation. Retry only that record;
   ambiguous sends require explicit approval of possible duplicate delivery.
7. Create a journal with a unique request key. Repeat the exact request to verify
   the retained outcome, then read it and use its signed token for confirmed deletion.

Check actual HTTP statuses and response bodies; a successful Yaak CLI exit code
does not mean an HTTP request succeeded. Expected successful statuses vary (200,
201, 202). Negative examples intentionally return 428, and stale mutations return
409. Responses use `data`/optional `meta` or a fixed `error.code`, with `no-store`.

## Automated regression coverage

Run `mix precommit` for compilation, formatting and the complete suite. Focused files:

| Behavior | Tests |
| --- | --- |
| All final resource routes authenticate before malformed bodies and conceal foreign campaigns | `test/async_worlds_web/http_api_coverage_test.exs` |
| HTTP/Discord personal results agree; DM HTTP journals preserve player privacy without changing debug personas | `test/async_worlds_web/http_api_coverage_test.exs` |
| Draft edits/rerolls, required reasons, stale tokens, approval, atomic publication and live drift | `test/async_worlds_web/controllers/tick_review_controller_test.exs` |
| Published pagination, immutable saved content, explicit DM subjects and revoked ownership | `test/async_worlds_web/controllers/history_controller_test.exs` |
| Filter/cursor bounds, redacted errors, generation checks and no republishing on retry | `test/async_worlds_web/controllers/delivery_controller_test.exs` |
| Journal cursor ceilings, attribution, retained idempotency and signed target/configuration deletion | `test/async_worlds_web/controllers/journal_controller_test.exs` |
| Credential-free Yaak requests resolve to real routes and contain valid JSON bodies | `test/async_worlds_web/api_examples_test.exs` |

Existing domain and LiveView suites additionally exercise the same actor-aware tick,
clock and delivery boundaries, publication concurrency, immutable history and
Discord journal controls. HTTP adapters do not duplicate those state machines.
