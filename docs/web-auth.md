# Discord OAuth web authentication (ENG-6)

The web console is for the configured campaign DM only. It requests Discord's
`identify` scope and stores neither the Discord access token nor profile payload.
The short-lived authorization code is exchanged with `Req`; production and tests
do not use another HTTP client.

## Discord application setup

In the Discord Developer Portal, add this exact production redirect URL to the
application's OAuth2 redirect allowlist:

```text
https://YOUR_HOST/auth/discord/callback
```

Configure the deployment with secrets supplied by its secret manager:

| Variable | Requirement |
| --- | --- |
| `DISCORD_OAUTH_CLIENT_ID` | Discord application/client ID. |
| `DISCORD_OAUTH_CLIENT_SECRET` | OAuth client secret; never expose it to the browser or logs. |
| `DISCORD_OAUTH_REDIRECT_URI` | Exact HTTPS callback URL registered above. |
| `SECRET_KEY_BASE` | Independent Phoenix secret, generated with `mix phx.gen.secret`. |
| `DATABASE_URL` | PostgreSQL connection used for OAuth states and sessions. |
| `PHX_HOST` | Public hostname used for HTTPS URLs. |

Bot configuration is independent: OAuth works whether `DISCORD_ENABLED` is true
or false. Local development may set the three `DISCORD_OAUTH_*` values in the
environment and use `http://localhost:4000/auth/discord/callback`, if that exact
URL is registered for the development application. Automated tests use
`Req.Test`; they need no Discord configuration, network access, or credentials.

## Security model

* OAuth state is 256 bits from `:crypto.strong_rand_bytes/1`, tied to the initiating
  encrypted browser session, stored only as a SHA-256 digest server-side, expires
  after ten minutes, and is atomically deleted on use. Denied callbacks consume it.
* Successful login rotates the Phoenix session and places only an opaque random
  handle in its encrypted, signed, HTTP-only cookie. Production cookies are
  `Secure`, `SameSite=Lax`, and limited to eight hours.
* Web sessions are persisted as token digests, expire after eight hours, and can
  be revoked. Logout revokes the database row before dropping the cookie and
  broadcasts revocation to connected LiveViews, preventing cookie replay.
* HTTP requests, disconnected mounts, connected mounts, and every LiveView event
  load the current server-side session and call `Campaigns.authorize_dm/2` against
  fresh campaign configuration. Browser campaign/user IDs and cached campaign
  records are never authorization authorities.
* Production forces HTTPS with HSTS. OAuth codes and credential-like request
  parameters are filtered from Phoenix logs. Failure messages reveal no upstream
  response, token, code, or profile data.

Changing the configured DM immediately blocks the old identity on its next HTTP
request or LiveView event. Explicit logout closes current sockets immediately.
Expired connected sessions are redirected by a server timer as well as by the
per-event check.
