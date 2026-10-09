defmodule AsyncWorlds.Discord.RegistrationTest do
  use AsyncWorlds.DataCase, async: false
  import ExUnit.CaptureLog

  alias AsyncWorlds.Campaigns
  alias AsyncWorlds.Discord.{Commands, FakeAdapter, Registration}

  setup do
    start_supervised!({FakeAdapter, owner: self()})
    %{opts: [adapter: FakeAdapter, guild_id: "123", application_id: "111"]}
  end

  test "bulk registration is repeatable and targets only the configured guild", %{opts: opts} do
    Campaigns.setup_campaign(%{
      discord_guild_id: "123",
      dm_user_id: "456",
      public_channel_id: "789"
    })

    for _ <- 1..2 do
      assert {:ok, definitions} = Registration.register(opts)
      assert definitions == Commands.definitions()
      assert_receive {:discord, :register_commands, {"111", "123", ^definitions}}
    end

    assert FakeAdapter.commands() == %{{"111", "123"} => Commands.definitions()}
    assert Enum.map(Commands.definitions(), & &1.name) == ["clocks", "tick", "admin"]

    assert Enum.map(Enum.at(Commands.definitions(), 1).options, & &1.name) == [
             "open",
             "close",
             "status"
           ]
  end

  test "invalid IDs and missing campaigns do not touch the transport", %{opts: opts} do
    assert {:error, :not_found} = Registration.register(opts)

    assert {:error, :invalid_configuration} =
             Registration.register(Keyword.put(opts, :guild_id, "0"))

    assert {:error, :invalid_configuration} =
             Registration.register(Keyword.put(opts, :application_id, "bad"))

    refute_receive {:discord, _, _}
  end

  test "registration failures do not expose response bodies or tokens", %{opts: opts} do
    Campaigns.setup_campaign(%{
      discord_guild_id: "123",
      dm_user_id: "456",
      public_channel_id: "789"
    })

    for failure <- [{:error, "bot-token-secret"}, {:raise, "bot-token-secret"}] do
      FakeAdapter.fail(:register_commands, failure)

      log =
        capture_log(fn -> assert {:error, :registration_failed} = Registration.register(opts) end)

      refute log =~ "bot-token-secret"
    end
  end
end
