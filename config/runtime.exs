import Config

# Load trusted, untracked local credentials before reading environment values.
# Runtime config does not support import_config; this file only sets env vars.
# Never load local secrets in tests or production.
if config_env() == :dev and
     System.get_env("ASYNC_WORLDS_LOAD_LOCAL_SECRETS", "true") != "false" do
  local_secrets = Path.join(__DIR__, "dev.secret.exs")

  if File.regular?(local_secrets) do
    Code.eval_file(local_secrets)
  end
end

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/async_worlds start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :async_worlds, AsyncWorldsWeb.Endpoint, server: true
end

config :async_worlds, AsyncWorldsWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# Never connect to Discord in the normal test environment, even if the shell
# contains production credentials. Local development is opt-in too.
if config_env() != :test do
  enabled = System.get_env("DISCORD_ENABLED", "false")

  unless enabled in ["true", "false"] do
    raise "DISCORD_ENABLED must be true or false"
  end

  if enabled == "true" do
    token = System.get_env("DISCORD_BOT_TOKEN")

    if is_nil(token) or String.trim(token) == "" do
      raise "DISCORD_BOT_TOKEN is required when DISCORD_ENABLED=true"
    end

    ids =
      for key <- ["DISCORD_GUILD_ID", "DISCORD_APPLICATION_ID"], into: %{} do
        value = System.get_env(key, "")

        unless byte_size(value) in 1..20 and Regex.match?(~r/\A[1-9][0-9]*\z/, value) and
                 String.to_integer(value) <= 18_446_744_073_709_551_615 do
          raise "#{key} must be a positive unsigned 64-bit Discord ID"
        end

        {key, value}
      end

    config :async_worlds, :discord,
      enabled: true,
      adapter: AsyncWorlds.Discord.NostrumAdapter,
      guild_id: ids["DISCORD_GUILD_ID"],
      application_id: ids["DISCORD_APPLICATION_ID"]

    config :nostrum, token: token
  end
end

if config_env() == :dev do
  config :async_worlds, :discord_oauth,
    client_id: System.get_env("DISCORD_OAUTH_CLIENT_ID"),
    client_secret: System.get_env("DISCORD_OAUTH_CLIENT_SECRET"),
    redirect_uri: System.get_env("DISCORD_OAUTH_REDIRECT_URI"),
    token_url: "https://discord.com/api/oauth2/token",
    profile_url: "https://discord.com/api/users/@me",
    request_options: []

  # Reload browser tabs when matching files change.
  config :async_worlds, AsyncWorldsWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$",
        # Gettext translations
        ~r"priv/gettext/.*\.po$",
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/async_worlds_web/router\.ex$",
        ~r"lib/async_worlds_web/(controllers|live|components)/.*\.(ex|heex)$"
      ]
    ]
end

if config_env() == :prod do
  required = fn key ->
    case System.get_env(key) do
      value when is_binary(value) ->
        if String.trim(value) == "", do: raise("#{key} is required in production"), else: value

      _ ->
        raise "#{key} is required in production"
    end
  end

  database_url = required.("DATABASE_URL")

  database_uri =
    case URI.new(database_url) do
      {:ok, uri} -> uri
      {:error, _} -> raise "DATABASE_URL must be a PostgreSQL connection URL"
    end

  unless database_uri.scheme in ["ecto", "postgres", "postgresql"] and
           is_binary(database_uri.host) and database_uri.host != "" and
           is_binary(database_uri.path) and Regex.match?(~r/\A\/[^\/]+\z/, database_uri.path) and
           is_nil(database_uri.fragment) do
    raise "DATABASE_URL must be a PostgreSQL connection URL"
  end

  # Do not let URL query options override the explicit TLS policy below.
  if database_uri.query,
    do: raise("DATABASE_URL query options are not supported; use DATABASE_SSL")

  ssl =
    case System.get_env("DATABASE_SSL", "verify") do
      "verify" ->
        ca_file = System.get_env("DATABASE_CA_CERT", "/etc/ssl/certs/ca-certificates.crt")
        unless File.regular?(ca_file), do: raise("DATABASE_CA_CERT must name a readable CA file")

        [
          verify: :verify_peer,
          cacertfile: String.to_charlist(ca_file),
          server_name_indication: String.to_charlist(database_uri.host),
          customize_hostname_check: [
            match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
          ]
        ]

      "disable" ->
        false

      _ ->
        raise "DATABASE_SSL must be verify or disable"
    end

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :async_worlds, AsyncWorlds.Repo,
    url: database_url,
    ssl: ssl,
    pool_size: String.to_integer(System.get_env("POOL_SIZE", "10")),
    socket_options: maybe_ipv6,
    # Postgrex connection errors can contain credentials; suppress driver detail
    # in production. Readiness exposes only a fixed diagnostic code.
    show_sensitive_data_on_connection_error: false

  secret_key_base = required.("SECRET_KEY_BASE")
  if byte_size(secret_key_base) < 64, do: raise("SECRET_KEY_BASE must be at least 64 bytes")
  host = required.("PHX_HOST")

  unless Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9.-]*\z/, host),
    do: raise("PHX_HOST must be a hostname without scheme or port")

  redirect_uri = required.("DISCORD_OAUTH_REDIRECT_URI")

  unless redirect_uri == "https://#{host}/auth/discord/callback",
    do: raise("DISCORD_OAUTH_REDIRECT_URI must match the HTTPS PHX_HOST callback")

  config :async_worlds, :discord_oauth,
    client_id: required.("DISCORD_OAUTH_CLIENT_ID"),
    client_secret: required.("DISCORD_OAUTH_CLIENT_SECRET"),
    redirect_uri: redirect_uri,
    token_url: "https://discord.com/api/oauth2/token",
    profile_url: "https://discord.com/api/users/@me",
    request_options: []

  config :async_worlds, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :async_worlds, AsyncWorldsWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :async_worlds, AsyncWorldsWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :async_worlds, AsyncWorldsWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :async_worlds, AsyncWorlds.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://swoosh.hexdocs.pm/Swoosh.html#module-installation for details.
end
