# AsyncWorlds

A Phoenix campaign engine with PostgreSQL persistence. See [the implementation
plan](docs/project-plan.md) for the project scope.

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

## Run and test

```sh
mix phx.server
mix precommit
```

Visit [localhost:4000](http://localhost:4000). Normal tests require PostgreSQL,
but no Discord connection. `mix precommit` compiles with warnings as errors,
checks dependencies, formats code and runs the test suite.
