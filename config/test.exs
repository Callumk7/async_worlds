import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :async_worlds, AsyncWorlds.Repo,
  username: System.get_env("PGUSER") || System.get_env("USER") || "postgres",
  password: System.get_env("PGPASSWORD"),
  hostname: System.get_env("PGHOST", "localhost"),
  port: String.to_integer(System.get_env("PGPORT", "5432")),
  database: "async_worlds_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# No bot process or real transport in the normal suite, regardless of shell credentials.
config :async_worlds, :discord,
  enabled: false,
  adapter: AsyncWorlds.Discord.FakeAdapter,
  guild_id: nil,
  application_id: nil

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :async_worlds, AsyncWorldsWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "NctVQwlFiOyIVE6XTKWxnCjxUeMotBX6cPXHwkiZ3HAjPXwAuiJ8icj7/p7rIS3v",
  server: false

# In test we don't send emails
config :async_worlds, AsyncWorlds.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
