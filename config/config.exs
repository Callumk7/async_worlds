# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :async_worlds,
  ecto_repos: [AsyncWorlds.Repo],
  generators: [timestamp_type: :utc_datetime]

config :async_worlds, :web_auth,
  state_ttl_seconds: 600,
  session_ttl_seconds: 28_800

config :async_worlds, :discord_oauth,
  client_id: nil,
  client_secret: nil,
  redirect_uri: nil,
  token_url: "https://discord.com/api/oauth2/token",
  profile_url: "https://discord.com/api/users/@me",
  request_options: []

# Nostrum is an included application: only our opt-in bot subtree starts it.
config :async_worlds, :discord,
  enabled: false,
  adapter: AsyncWorlds.Discord.NostrumAdapter,
  guild_id: nil,
  application_id: nil

config :nostrum,
  gateway_intents: [],
  ffmpeg: false,
  youtubedl: false,
  streamlink: false

# Configure the endpoint
config :async_worlds, AsyncWorldsWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: AsyncWorldsWeb.ErrorHTML, json: AsyncWorldsWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: AsyncWorlds.PubSub,
  live_view: [signing_salt: "737rK2iD"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :async_worlds, AsyncWorlds.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  async_worlds: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.3",
  async_worlds: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :discord_stage]

# Prevent short-lived OAuth codes and all credential-like parameters from logs.
config :phoenix, :filter_parameters, ["password", "token", "secret", "code"]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
