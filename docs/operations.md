# Container release and operations (ENG-11)

## Scope and prerequisites

One persistent Phoenix container runs web, the optional Nostrum bot and Oban.
Provision PostgreSQL separately; the application does **not** create a production
DB/role, select a hosting provider, or configure a public gateway. Use PostgreSQL
16+ and a durable volume/managed database, not the application's writable layer.
Run **one application instance per database/guild**. Oban can distribute jobs, but
that is not permission to run two Discord gateway consumers. Do not autoscale or
use rolling/blue-green overlap. Existing DM authorization and secure cookies are
unchanged; configuring campaign IDs does not bypass Discord OAuth.

The multi-stage `Dockerfile` builds assets and an OTP release with Elixir 1.18
(project requires >=1.17), then copies only the release into a non-root Debian
runtime. No build args contain secrets. `.dockerignore` and explicit `COPY` paths
exclude local credentials, repository history, tests and build outputs. Supply
secrets **only at runtime**, never via Docker build arguments/layers. Tags are
mutable: rebuild for security updates, review builder/runtime compatibility, and
record/deploy the resulting image digest for reproducible rollbacks.

```sh
docker build -t async-worlds:ENG-11 .
```

## Runtime configuration

Inject a secret manager or a mode-0600 environment file outside the repository.
Do not paste secrets into command arguments, shell history, logs or bug reports.
Docker admins can inspect environment values; restrict Docker access accordingly.

| Variable | Meaning |
| --- | --- |
| `DATABASE_URL` | Required `postgres://USER:PERCENT_ENCODED_PASSWORD@HOST:5432/DATABASE` (also `postgresql`/`ecto`). No query options; policy is configured below. Least-privilege app role; use an operator role for DDL if appropriate. |
| `DATABASE_SSL` | `verify` by default: verify CA **and hostname**, no insecure fallback. `disable` only for explicitly trusted local/private plaintext databases. `require`/skip-verification modes are intentionally unsupported. |
| `DATABASE_CA_CERT` | Readable PEM CA bundle inside the container, default `/etc/ssl/certs/ca-certificates.crt`. Mount private/provider CA read-only. Use a DNS hostname matching the DB certificate, not an arbitrary IP. |
| `SECRET_KEY_BASE` | Required independent random secret, at least 64 bytes. Generate with `mix phx.gen.secret` or `openssl rand -base64 64`. Stable across restarts; rotation invalidates cookies. |
| `PHX_HOST` | Required public hostname, without scheme/path/port. |
| `PORT` | Internal HTTP port, default 4000. The Docker healthcheck uses 4000; override the healthcheck if changing it. |
| `PHX_SERVER` | Image defaults to `true`; release eval commands do not start the web server. |
| `POOL_SIZE`, `ECTO_IPV6` | Pool size (default 10); set IPv6 to `true`/`1` only if DB networking requires it. |
| `DISCORD_OAUTH_CLIENT_ID`, `DISCORD_OAUTH_CLIENT_SECRET` | Required even when the bot is off, for the DM web login. |
| `DISCORD_OAUTH_REDIRECT_URI` | Must be exactly `https://PHX_HOST/auth/discord/callback`, also registered in Discord's OAuth redirect allowlist. |
| `DISCORD_ENABLED` | `false` by default; web starts without bot credentials. Only `true` or `false`. |
| `DISCORD_BOT_TOKEN` | Required only when bot enabled. Separate from OAuth secret. |
| `DISCORD_APPLICATION_ID`, `DISCORD_GUILD_ID` | Required positive unsigned 64-bit Discord IDs when bot enabled. |
| `DISCORD_DM_USER_ID`, `DISCORD_PUBLIC_CHANNEL_ID` | Used by release setup, together with `DISCORD_GUILD_ID`; persisted campaign configuration is the authority, not these env vars during requests. |

Missing/invalid required config fails before application startup with variable
names, not values. Production never loads `config/dev.secret.exs`. Keep OAuth and
bot apps consistent. For guild command registration/permissions see [Discord
operations](discord.md); use the documented Mix operator task from a trusted
source checkout for command registration. Never register commands in smoke tests.

## First install and rollout

Create the DB and role externally first. Pass the same runtime config and CA mount
to migration, setup and application containers. Example assumes an operator-managed
network `worlds-private` and `/secure/worlds.env` (do not create these blindly on a
shared Docker host). Add `-v /secure/db-ca.pem:/run/db-ca.pem:ro` and
`DATABASE_CA_CERT=/run/db-ca.pem` when needed.

```sh
# Neither helper starts Discord, Oban or the web server.
docker run --rm --network worlds-private --env-file /secure/worlds.env \
  async-worlds:ENG-11 /app/bin/async_worlds eval 'AsyncWorlds.Release.migrate()'
docker run --rm --network worlds-private --env-file /secure/worlds.env \
  async-worlds:ENG-11 /app/bin/async_worlds eval 'AsyncWorlds.Release.setup()'
# Setup is idempotent by guild. Changing the DM immediately changes authorization;
# it preserves tick history and does not validate guild/channel ownership remotely.
docker run -d --name worlds-app --network worlds-private \
  --env-file /secure/worlds.env --restart unless-stopped --stop-timeout 90 \
  -p 127.0.0.1:4000:4000 async-worlds:ENG-11
```

For an upgrade: take/verify a backup; **stop the old app/bot before starting any
new app instance** (`docker stop -t 90 worlds-app`); run migrations once; run setup
only if configuration needs changing; replace with the new digest; check readiness
and DM login. This is a short-downtime rollout, not a hosting commitment. Migration
failure aborts rollout: never start a new bot against a partially upgraded DB.
Migrations do not run automatically on application startup. Roll back an image
only if its schema is compatible; otherwise restore a tested backup with the app
stopped. Do not blindly roll back Oban migrations or drop queue tables.

## HTTPS, health, logs and restart

Put an HTTPS-terminating trusted reverse proxy in front of the private HTTP port,
forward WebSocket upgrades, preserve Host, and set/overwrite `X-Forwarded-Proto`.
Do not allow untrusted clients to reach the backend or spoof forwarded headers.
Production still redirects to HTTPS with HSTS and uses encrypted, HttpOnly, Secure,
SameSite=Lax cookies. Only the two health paths (and existing localhost exclusions)
are exempt from HTTP redirection. OAuth and DM routes remain protected.

* `GET /health/live`: 200 `{"status":"ok"}` while HTTP/BEAM is responsive.
* `GET /health/ready`: 200 with `database: "ok"` after a bounded DB query can access
  campaigns and Oban schema; otherwise 503 with **only** `database: "unavailable"`
  and `status: "unavailable"`. No URL, SQL, exception, token or user data. This is
  DB readiness, not a Discord connectivity check, exhaustive schema-version test,
  or proof of campaign setup. Check migration output and setup separately.
* Docker's HEALTHCHECK uses readiness. An unhealthy status does **not** itself
  restart Docker containers. Alert/investigate DB availability/permissions/TLS
  before restarting. Avoid liveness restarts during a database outage.
* Logs go to stdout/stderr (`docker logs worlds-app`). Configure platform retention,
  rotation and access control; do not enable transport debugging or dump process
  state. Postgrex sensitive-connection diagnostics are disabled. Readiness returns
  a safe fixed diagnostic; use secured DB tools for deeper diagnosis.
* Exec-form entrypoint gives the BEAM SIGTERM. `docker stop -t 90` allows OTP/Oban
  to drain workers (production Oban grace is 65s; resolution timeout is 60s)
  before Docker SIGKILL. Avoid a default
  10s deadline. Normal exits are clean; `unless-stopped` restarts crashes/daemon
  restarts, but not an explicitly stopped container. Test operational stop/start.
* Pending/scheduled/retryable Oban work lives in PostgreSQL, not memory. Lifeline
  rescues interrupted executing jobs after five minutes. Resolution is retry-safe;
  interrupted Discord sends can be **ambiguous**, not exactly-once. Disabled bots
  snooze delivery without sending. See [durable work](durable-work.md) before
  retrying or recovering deliveries; never republish to fix delivery failures.

## Backup and restore

Use managed automated backups/PITR where available, plus regular restore drills.
For a logical backup use PostgreSQL client tools compatible with the server,
credentials via protected `.pgpass`/service files, and TLS `sslmode=verify-full`
with `sslrootcert` set to the trusted CA. Avoid secret URLs on CLI arguments.
`PGSERVICE` below refers to an operator-managed protected `pg_service.conf` entry.

```sh
umask 077
PGSERVICE=worlds-backup pg_dump --format=custom --no-owner --file=worlds.dump
# Separately preserve required roles/grants (DB admin), deployment configuration,
# CA material and secrets in your encrypted secret/backup system, not this repo.
# Stop the application before restoring to a newly provisioned empty database.
PGSERVICE=worlds-restore pg_restore --exit-on-error --single-transaction \
  --no-owner --no-acl --dbname=worlds_restored worlds.dump
```

Encrypt backups at rest, restrict access (private campaign content and session
hashes are included), store off-host, monitor failures, and define retention/RPO/
RTO with the operator. Validate restored campaign/history, migrations and queue
counts in an isolated environment with **bot disabled** before switching the one
live app. A backup restore can reintroduce old pending sends; inspect delivery
records and Discord receipts before enabling the bot. Never run two restored bots
against the same guild. Validate provider certificate rotation before expiry;
never solve TLS failure by disabling verification in production.

## Local PostgreSQL and repeatable container smoke

For development, an isolated local DB can be started without touching existing
containers. Pick unique names/port and save the generated password outside Git:

```sh
docker run -d --name worlds-dev-db --restart unless-stopped \
  -e POSTGRES_PASSWORD="$LOCAL_DB_PASSWORD" \
  -p 127.0.0.1:55432:5432 -v worlds-dev-pg:/var/lib/postgresql/data postgres:16-alpine
export PGHOST=localhost PGPORT=55432 PGUSER=postgres PGPASSWORD="$LOCAL_DB_PASSWORD"
mix setup
mix precommit
```

The smoke script **requires a separately supplied disposable empty PostgreSQL
DB**; it migrates and writes campaign/job rows, but never creates/stops/deletes
the supplied DB or caller network. Do not point it at production or a shared DB.
The caller provisions/cleans its own uniquely named database/network. It builds
the release unless `SMOKE_SKIP_BUILD=true`; uses dummy OAuth and no bot token.

```sh
SMOKE_DATABASE_URL="$DISPOSABLE_DB_URL" SMOKE_ALLOW_DATABASE_WRITES=yes \
  SMOKE_NETWORK=your-unique-test-network SMOKE_DATABASE_SSL=disable \
  SMOKE_LOG_DIR=/tmp/worlds-smoke scripts/container-smoke.sh
# For a TLS DB: default verify, optionally SMOKE_CA_CERT=/absolute/path/ca.pem.
```

It checks actual release migrations twice, setup twice, required-config failures,
HTTP probes and safe DB failure, HTTPS enforcement, Secure/HttpOnly OAuth cookies,
DM login protection, absence of gateway processes, SIGTERM exit, automatic crash
restart and a scheduled Oban job's ID/payload/schedule/state across both restarts.
It cancels its job and removes only its uniquely named app container. Test DB
campaign/canceled job remain for inspection; destroy only your own disposable DB.
No real Discord request or credentials are used. This does not substitute for a
provider-specific TLS/backup restore drill or a supervised real Discord rehearsal.
