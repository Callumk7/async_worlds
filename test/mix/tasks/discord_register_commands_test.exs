defmodule Mix.Tasks.Discord.RegisterCommandsTest do
  use AsyncWorlds.DataCase, async: false
  import ExUnit.CaptureLog

  alias AsyncWorlds.Campaigns
  alias AsyncWorlds.Discord.FakeAdapter
  alias Mix.Tasks.Discord.RegisterCommands

  setup do
    start_supervised!({FakeAdapter, owner: self()})
    previous = Application.fetch_env!(:async_worlds, :discord)
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      Application.put_env(:async_worlds, :discord, previous)
      Mix.shell(previous_shell)
    end)

    Application.put_env(:async_worlds, :discord,
      enabled: true,
      adapter: FakeAdapter,
      application_id: "111",
      guild_id: "123"
    )

    :ok
  end

  test "task registers repeatably with no gateway" do
    Campaigns.setup_campaign(%{
      discord_guild_id: "123",
      dm_user_id: "456",
      public_channel_id: "789"
    })

    for _ <- 1..2 do
      RegisterCommands.run([])
      assert_receive {:mix_shell, :info, ["Registered 3 commands in guild 123"]}
    end

    assert Process.whereis(Nostrum.Supervisor) == nil
  end

  test "task rejects arguments, disabled bot and missing campaign" do
    assert_raise Mix.Error, ~r/takes no arguments/, fn -> RegisterCommands.run(["321"]) end
    assert_raise Mix.Error, ~r/run mix campaign.setup first/, fn -> RegisterCommands.run([]) end
    Application.put_env(:async_worlds, :discord, enabled: false)
    assert_raise Mix.Error, ~r/DISCORD_ENABLED=true/, fn -> RegisterCommands.run([]) end
  end

  test "task reports transport failures without leaking secrets" do
    Campaigns.setup_campaign(%{
      discord_guild_id: "123",
      dm_user_id: "456",
      public_channel_id: "789"
    })

    FakeAdapter.fail(:register_commands, {:error, "bot-token-secret"})

    log =
      capture_log(fn ->
        assert_raise Mix.Error, ~r/check the token/, fn -> RegisterCommands.run([]) end
      end)

    refute log =~ "bot-token-secret"
  end
end
