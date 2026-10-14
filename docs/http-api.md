# HTTP API authentication (ENG-48)

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
Tick lifecycle, readiness and reminder routes are documented in [HTTP ticks](http-ticks.md).
Draft review, previews, audited edits and publication are documented in [HTTP tick review](http-tick-review.md).
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

- [Published and personal history](http-history.md)

- [Delivery inspection and retry](http-deliveries.md)

- [Journal operations](http-journals.md)
