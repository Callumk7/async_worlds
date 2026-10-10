defmodule AsyncWorlds.RuntimeConfigTest do
  use ExUnit.Case, async: false

  @values %{
    "DATABASE_URL" => "postgres://user:private-db-password@db.example/worlds",
    "DATABASE_SSL" => "verify",
    "SECRET_KEY_BASE" => String.duplicate("s", 64),
    "PHX_HOST" => "worlds.example",
    "DISCORD_OAUTH_CLIENT_ID" => "dummy",
    "DISCORD_OAUTH_CLIENT_SECRET" => "private-oauth-secret",
    "DISCORD_OAUTH_REDIRECT_URI" => "https://worlds.example/auth/discord/callback",
    "DISCORD_ENABLED" => "false"
  }

  setup do
    keys = Map.keys(@values) ++ ["DATABASE_CA_CERT", "DISCORD_BOT_TOKEN"]
    previous = Map.new(keys, &{&1, System.get_env(&1)})
    Enum.each(keys, &System.delete_env/1)
    System.put_env(@values)
    # Certifi is bundled with the app on every supported OS; no Debian CA dependency.
    System.put_env("DATABASE_CA_CERT", List.to_string(:certifi.cacertfile()))

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    :ok
  end

  test "TLS verifies CA and database hostname by default, without starting the bot" do
    config = runtime()
    ssl = config[:async_worlds][AsyncWorlds.Repo][:ssl]
    assert ssl[:verify] == :verify_peer
    assert ssl[:cacertfile] == :certifi.cacertfile()
    assert ssl[:server_name_indication] == ~c"db.example"
    assert is_function(ssl[:customize_hostname_check][:match_fun], 2)
    assert Process.whereis(AsyncWorlds.Discord.Supervisor) == nil
    System.put_env("DATABASE_SSL", "disable")
    assert runtime()[:async_worlds][AsyncWorlds.Repo][:ssl] == false
  end

  test "required values, callback and TLS mistakes fail closed without printing secrets" do
    for key <- Map.keys(@values) -- ["DISCORD_ENABLED", "DATABASE_SSL"] do
      System.put_env(key, " ")
      assert_raise RuntimeError, ~r/#{key}/, &runtime/0
      System.put_env(key, @values[key])
    end

    for {key, value} <- [
          {"DATABASE_URL", "postgres://user:private-db-password@db.example/worlds?ssl=false"},
          {"DATABASE_URL", "postgres://user:private-db-password@db.example:bad/worlds"},
          {"DATABASE_SSL", "require"},
          {"DATABASE_CA_CERT", "/missing/private-ca"},
          {"SECRET_KEY_BASE", "short-private-secret"},
          {"PHX_HOST", "https://worlds.example"},
          {"DISCORD_OAUTH_REDIRECT_URI", "http://worlds.example/auth/discord/callback"},
          {"DISCORD_ENABLED", "true"}
        ] do
      previous = System.get_env(key)
      System.put_env(key, value)
      error = assert_raise RuntimeError, &runtime/0
      refute Exception.message(error) =~ "private"

      if is_nil(previous),
        do: System.delete_env(key),
        else: System.put_env(key, previous)
    end
  end

  test "malformed database paths fail safely before Ecto can include credentials in its error" do
    System.put_env("DATABASE_URL", "postgres://user:private-db-password@db.example/worlds/extra")
    error = assert_raise RuntimeError, ~r/DATABASE_URL/, &runtime/0
    refute Exception.message(error) =~ "private-db-password"
  end

  defp runtime, do: Config.Reader.read!("config/runtime.exs", env: :prod, target: :host)
end
