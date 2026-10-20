# AsyncWorlds

A Phoenix campaign engine with PostgreSQL persistence. The active direction is
[Tension-led world play](docs/tension-led-world-play.md). Start with the
[DM and player operating guide](docs/tension-led-operating-guide.md) for the
implemented loop and [rehearsal record](docs/tension-led-rehearsal.md) for outstanding
live Discord validation. Existing quest campaigns remain supported.
The [flexible-actions plan](docs/flexible-actions-plan.md),
[original MVP outline](docs/archive/project-outline.md) and
[implementation plan with closeout](docs/archive/project-plan.md) are historical baselines.
See the [documentation audit](docs/documentation-audit.md) for implementation/test
coverage and remaining verification boundaries.

For production releases, runtime secrets/TLS, migration and campaign setup,
health probes, single-bot rollouts, backup/restore and the repeatable external-DB
container smoke test, see [operations](docs/operations.md).

## Local PostgreSQL setup

Install Elixir/Erlang and PostgreSQL, then start PostgreSQL before running Mix.
For example, on macOS with Homebrew:

```sh
brew install postgresql@18
brew services start postgresql@18
```

Development and test connections use `PGUSER` (defaults to your OS `USER`, then
`postgres`), optional `PGPASSWORD`, `PGHOST` (default `localhost`), and `PGPORT`
(default `5432`). The role must already exist and have permission to create
local databases. Homebrew normally creates a role for your OS user. For other
installations, use the PostgreSQL administrator role or ask your administrator
to provision a development role. No manual SQL is needed for application setup.

```sh
# Override these only if your PostgreSQL installation needs them:
export PGUSER="your_postgres_role"
export PGHOST="localhost"
export PGPORT="5432"
# export PGPASSWORD="your_local_password"

mix setup
```

`mix setup` installs dependencies, creates `async_worlds_dev`, runs migrations,
and builds assets. Tests create and migrate the separate `async_worlds_test`
database (with a partition suffix when `MIX_TEST_PARTITION` is set). Production
uses `DATABASE_URL`, as configured in `config/runtime.exs`.

For database-only setup after dependencies are installed, use `mix ecto.setup`.
After pulling new migrations, use `mix ecto.migrate`. Connection or permission
errors should be resolved by checking the PostgreSQL service and the variables
above; do not edit the database manually.

## Configure a campaign

Enable Discord Developer Mode and copy the server (guild), DM user's account,
and public channel IDs. Use the **user ID**, not the username or discriminator.

```sh
mix campaign.setup \
  --guild-id 123456789012345678 \
  --dm-user-id 234567890123456789 \
  --public-channel-id 345678901234567890
```

All three options are required. IDs must be positive decimal unsigned 64-bit
integers, without spaces, signs or leading zeroes. They are persisted as strings
so even IDs beyond JavaScript's safe integer or PostgreSQL's signed bigint range
retain their precision. Keep IDs as strings in JSON/browser payloads.

Setup atomically creates one campaign per guild. Re-running it updates the DM
and public channel while preserving the campaign's ID and current tick number
(initially zero). Tick progression cannot be set through this task. Invalid
configuration returns field-specific errors without changing the campaign.
Setup is a trusted local operator command; it does not authenticate the caller.
No Discord token or network connection is required, and setup only validates ID
format—it cannot verify channel ownership or Discord permissions.

Web and Discord interfaces share `AsyncWorlds.Campaigns`:

- `fetch_campaign_by_guild/1` returns `{:ok, campaign}`, `{:error, :invalid_id}`
  or `{:error, :not_found}`.
- `dm?/2` compares a loaded campaign with a Discord user ID, failing closed for
  invalid identities.
- `authorize_dm/2` fetches current guild configuration and returns the campaign
  only to its configured DM; other identities receive `{:error, :unauthorized}`.
  Use this at protected operation boundaries rather than trusting cached setup
  data. The caller must obtain the user ID from a verified Discord interaction
  or authenticated web identity, not an untrusted form field.

## HTTP APIs

HTTP APIs use a manually configured DM bearer token shared with quest imports.
See [HTTP API authentication](docs/http-api.md) for configuration,
authorization boundaries and rotation.

## Discord bot

The optional supervised Nostrum bot is disabled by default. See
[Discord setup and operating notes](docs/discord.md) for installation,
runtime secrets, repeatable `mix discord.register_commands`, permissions and
live smoke-test steps. Tick controls, private character/quest/result retrieval,
journals, Tension intentions, the Event chronicle and DM testing personas are
implemented. Normal tests always stay offline.

## Tick resolution and DM review

`AsyncWorlds.Ticks.WorldResolver` deterministically resolves frozen world and quest
inputs into a DM-only, JSON-compatible draft. Current closes use version-3
snapshots; legacy version-1/2 snapshots remain supported. The pure engine applies
quest effects, background rates and world triggers without database writes or
Discord calls. Tension intentions are frozen for explicit DM adjudication, not
automatically interpreted as effects.
See [resolution decisions and the draft contract](docs/world-resolution.md).
Closing now atomically queues an Oban resolution job, which persists the draft
and moves the tick to review. The durable delivery outbox supports public/private
sends and targeted failure retries; see [durable work](docs/durable-work.md).
Audited edits and atomic publication are available through the private DM console.
See [the console operating guide](docs/dm-console.md) for the dashboard, clock
forms, review/preview/publish workflow, and targeted delivery retries. The
[Tension synthesis workspace](docs/tension-synthesis.md) adds private interpretation
and staged Event bundles to this same publication boundary. Run `mix ecto.migrate`
before starting an upgraded version.

## Characters

The DM editor at `/characters` links Discord players, supports DM-controlled
characters and manages strictly typed flags with explicit visibility. `/character`
privately retrieves only the invoking member's permitted state. See
[character APIs and security boundaries](docs/characters.md). Quest assignment and
authoring are available at `/quests` and `/quests/library`; see
[quest operations](docs/quest-operations.md). Resource accounting is not implemented.
Apply migrations and re-register guild commands when upgrading.

## Link history foundation

`AsyncWorlds.LinkHistory` retains DM-only, tick-linked entity-link state changes
for future timelines. Trusted domain callbacks commit current-state writes and
history atomically; changes belong to the open tick or otherwise the next tick,
even before its row exists. See [the writer/query contract](docs/link-history.md).
[Memberships](docs/memberships.md) and [location hierarchy](docs/locations.md) use
this foundation through shared domain operations, DM console controls and HTTP
APIs. They add no player relationship outputs or gameplay effects. Run
`mix ecto.migrate` when upgrading.

## Local development credentials

To avoid terminal exports, fill in `config/dev.secret.exs`. This ignored local
file sets the Discord OAuth and optional bot environment values before runtime
configuration reads them. It is loaded only in development, never in tests or
production. Its values override matching shell variables. If the file is absent,
the application continues using the shell environment as usual. Set
`ASYNC_WORLDS_LOAD_LOCAL_SECRETS=false` to bypass the file explicitly (also used
by runtime configuration tests so they never load real local credentials).

For web login, provide the OAuth client ID and client secret, and register
`http://localhost:4000/auth/discord/callback` in the Discord application's OAuth2
redirect allowlist. Leave `DISCORD_ENABLED` as `false` unless you also configure
the bot token, application ID and guild ID. Restart Phoenix after changes.
Never commit or share this file; production should use deployment secrets.

## Run and test

```sh
mix phx.server
mix precommit
```

Visit [localhost:4000](http://localhost:4000). Normal tests require PostgreSQL,
but no Discord connection. `mix precommit` compiles with warnings as errors,
checks dependencies, formats code and runs the test suite.
