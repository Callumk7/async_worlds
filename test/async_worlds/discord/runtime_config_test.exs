defmodule AsyncWorlds.Discord.RuntimeConfigTest do
  use ExUnit.Case, async: false

  @keys ~w(DISCORD_ENABLED DISCORD_BOT_TOKEN DISCORD_GUILD_ID DISCORD_APPLICATION_ID ASYNC_WORLDS_LOAD_LOCAL_SECRETS)

  setup do
    previous = Map.new(@keys, &{&1, System.get_env(&1)})
    Enum.each(@keys, &System.delete_env/1)
    # Config.Reader simulates development here; never load a developer's real secrets.
    System.put_env("ASYNC_WORLDS_LOAD_LOCAL_SECRETS", "false")

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    :ok
  end

  test "normal app has no gateway and includes Nostrum without auto-starting it" do
    assert Application.get_env(:async_worlds, :discord)[:enabled] == false
    assert Process.whereis(Nostrum.Supervisor) == nil
    assert Process.whereis(AsyncWorlds.Discord.Supervisor) == nil
    assert :nostrum in Application.spec(:async_worlds, :included_applications)
    started = Enum.map(Application.started_applications(), &elem(&1, 0))
    assert :nostrum not in started
    # Nostrum is started as a supervised included app, so its transport
    # dependencies must be explicitly available before that subtree starts.
    assert Enum.all?([:gun, :cowlib, :certifi, :inets], &(&1 in started))
    assert Application.get_env(:nostrum, :gateway_intents) == []
    assert AsyncWorlds.Application.discord_children(enabled: false) == []

    assert AsyncWorlds.Application.discord_children(enabled: true) == [
             {AsyncWorlds.Discord.Supervisor, []}
           ]
  end

  test "test runtime ignores credentials and even invalid Discord shell configuration" do
    System.put_env("DISCORD_ENABLED", "invalid")
    System.put_env("DISCORD_BOT_TOKEN", "should-not-be-used")
    config = read_runtime(:test)
    refute Keyword.has_key?(config, :nostrum)
    refute Keyword.has_key?(Keyword.get(config, :async_worlds, []), :discord)
  end

  test "development is opt-in and validates required configuration before connecting" do
    refute Keyword.has_key?(read_runtime(:dev), :nostrum)
    System.put_env("DISCORD_ENABLED", "true")
    assert_raise RuntimeError, ~r/DISCORD_BOT_TOKEN is required/, fn -> read_runtime(:dev) end
    System.put_env("DISCORD_BOT_TOKEN", "private-token")
    assert_raise RuntimeError, ~r/DISCORD_GUILD_ID must be/, fn -> read_runtime(:dev) end
    System.put_env("DISCORD_GUILD_ID", "123")
    assert_raise RuntimeError, ~r/DISCORD_APPLICATION_ID must be/, fn -> read_runtime(:dev) end

    for invalid <- ["0", "01", "18446744073709551616", "1\n", "abc"] do
      System.put_env("DISCORD_APPLICATION_ID", invalid)
      assert_raise RuntimeError, ~r/DISCORD_APPLICATION_ID must be/, fn -> read_runtime(:dev) end
    end

    System.put_env("DISCORD_APPLICATION_ID", "111")
    config = read_runtime(:dev)
    assert config[:nostrum][:token] == "private-token"
    assert config[:async_worlds][:discord][:enabled]
    assert config[:async_worlds][:discord][:guild_id] == "123"
    assert config[:async_worlds][:discord][:application_id] == "111"
    assert Process.whereis(Nostrum.Supervisor) == nil
  end

  test "invalid enable flag is rejected" do
    System.put_env("DISCORD_ENABLED", "yes")

    assert_raise RuntimeError, ~r/DISCORD_ENABLED must be true or false/, fn ->
      read_runtime(:dev)
    end
  end

  defp read_runtime(env), do: Config.Reader.read!("config/runtime.exs", env: env, target: :host)
end
