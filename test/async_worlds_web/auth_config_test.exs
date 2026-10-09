defmodule AsyncWorldsWeb.AuthConfigTest do
  use ExUnit.Case, async: false

  test "production runtime preserves compile-time TLS and trusted proxy settings" do
    values = %{
      "DATABASE_URL" => "ecto://test:test@localhost/unused",
      "SECRET_KEY_BASE" => String.duplicate("test-only-", 8),
      "DISCORD_ENABLED" => "false",
      "DISCORD_OAUTH_CLIENT_ID" => "test-client",
      "DISCORD_OAUTH_CLIENT_SECRET" => "test-secret",
      "DISCORD_OAUTH_REDIRECT_URI" => "https://example.com/auth/discord/callback"
    }

    previous = Map.new(values, fn {key, _} -> {key, System.get_env(key)} end)
    Enum.each(values, fn {key, value} -> System.put_env(key, value) end)

    try do
      compiled = Config.Reader.read!("config/prod.exs", env: :prod, target: :host)
      runtime = Config.Reader.read!("config/runtime.exs", env: :prod, target: :host)
      endpoint = AsyncWorldsWeb.Endpoint
      tls = compiled[:async_worlds][endpoint][:force_ssl]
      assert tls[:rewrite_on] == [:x_forwarded_proto]
      assert Keyword.get(tls, :hsts, true)
      runtime_tls = runtime[:async_worlds][endpoint][:force_ssl]
      assert is_nil(runtime_tls) or runtime_tls == tls
    after
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end
  end
end
