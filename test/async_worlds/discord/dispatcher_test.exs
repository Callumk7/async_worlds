defmodule AsyncWorlds.Discord.DispatcherTest do
  use AsyncWorlds.DataCase, async: false
  import ExUnit.CaptureLog

  alias AsyncWorlds.Campaigns
  alias AsyncWorlds.Discord.{Dispatcher, FakeAdapter, TestHandler}

  setup do
    start_supervised!({FakeAdapter, owner: self()})

    {:ok, campaign} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "123",
        dm_user_id: "456",
        public_channel_id: "789"
      })

    opts = [adapter: FakeAdapter, guild_id: "123", application_id: "111", handler: TestHandler]

    interaction = %Nostrum.Struct.Interaction{
      id: 1000,
      application_id: 111,
      type: 2,
      guild_id: 123,
      member: %Nostrum.Struct.Guild.Member{user_id: 456},
      user: %Nostrum.Struct.User{id: 456},
      token: "private-interaction-token",
      data: %Nostrum.Struct.ApplicationCommandInteractionData{
        name: "tick",
        options: [%{type: 1, name: "status"}]
      }
    }

    %{opts: opts, interaction: interaction, campaign: campaign}
  end

  test "acknowledges before executing and passes verified context to the handler", %{
    opts: opts,
    interaction: interaction,
    campaign: campaign
  } do
    assert {:ok, content} = Dispatcher.handle(interaction, opts)
    assert content =~ "campaign #{campaign.id}, user 456, interaction 1000"
    assert_receive {:discord, :defer, %{id: "1000", application_id: "111"}}
    assert_receive {:discord, :edit_response, {_, ^content}}
  end

  test "every DM command denies other users, other guilds and missing guild members", %{
    opts: opts,
    interaction: interaction,
    campaign: campaign
  } do
    cases = [
      %{interaction | member: %{user_id: 999}},
      %{interaction | guild_id: 321},
      %{interaction | guild_id: nil},
      %{interaction | member: nil, user: %{id: 456}},
      %{interaction | member: %{user_id: "0456"}}
    ]

    for {bad, i} <- Enum.with_index(cases), command <- ["open", "close", "status", "admin"] do
      data =
        if command == "admin",
          do: %{name: "admin"},
          else: %{name: "tick", options: [%{name: command, type: 1}]}

      bad = %{
        bad
        | id:
            2000 + i * 10 +
              Enum.find_index(["open", "close", "status", "admin"], &(&1 == command)),
          data: data
      }

      assert {:error, :unauthorized} = Dispatcher.handle(bad, opts)
      assert_receive {:discord, :defer, _}

      assert_receive {:discord, :edit_response,
                      {_, "This command is not available to you in this server."}}
    end

    assert Repo.get!(Campaigns.Campaign, campaign.id).current_tick_number == 0
  end

  test "a configured campaign in another guild is still denied", %{
    opts: opts,
    interaction: interaction
  } do
    Campaigns.setup_campaign(%{
      discord_guild_id: "321",
      dm_user_id: "456",
      public_channel_id: "987"
    })

    assert {:error, :unauthorized} = Dispatcher.handle(%{interaction | guild_id: 321}, opts)
  end

  test "players can route clocks but not in an unconfigured guild", %{
    opts: opts,
    interaction: interaction
  } do
    clocks = %{interaction | data: %{name: "clocks"}, member: %{user_id: 999}}
    assert {:ok, _} = Dispatcher.handle(clocks, opts)
    assert {:error, :unauthorized} = Dispatcher.handle(%{clocks | id: 1001, guild_id: 321}, opts)
  end

  test "authorization uses current DM configuration", %{opts: opts, interaction: interaction} do
    Campaigns.setup_campaign(%{
      discord_guild_id: "123",
      dm_user_id: "999",
      public_channel_id: "789"
    })

    assert {:error, :unauthorized} = Dispatcher.handle(interaction, opts)
  end

  test "unknown or malformed commands get private replies without a transition", %{
    opts: opts,
    interaction: interaction,
    campaign: campaign
  } do
    for {data, i} <-
          Enum.with_index([
            nil,
            %{name: "unknown"},
            %{name: "tick", options: []},
            %{name: "tick", options: [%{type: 1, name: "open", options: [%{}]}]},
            %{name: "clocks", options: [%{}]}
          ]) do
      assert {:error, :unknown_command} =
               Dispatcher.handle(%{interaction | id: 3000 + i, data: data}, opts)

      assert_receive {:discord, :defer, _}
      assert_receive {:discord, :edit_response, {_, "This command is not supported."}}
    end

    assert Repo.get!(Campaigns.Campaign, campaign.id).current_tick_number == 0
  end

  test "duplicate acknowledgments and new interaction IDs cannot bypass domain guards", %{
    opts: opts,
    interaction: interaction,
    campaign: campaign
  } do
    open = %{interaction | data: %{name: "tick", options: [%{type: 1, name: "open"}]}}
    assert {:ok, "Opened"} = Dispatcher.handle(open, opts)

    capture_log(fn ->
      assert {:error, :acknowledgment_failed} = Dispatcher.handle(open, opts)
      assert {:error, :invalid_transition} = Dispatcher.handle(%{open | id: 1001}, opts)
    end)

    assert Repo.get!(Campaigns.Campaign, campaign.id).current_tick_number == 1
  end

  test "acknowledgment errors and exceptions stop domain execution and redact secrets", %{
    opts: opts,
    interaction: interaction,
    campaign: campaign
  } do
    open = %{interaction | data: %{name: "tick", options: [%{type: 1, name: "open"}]}}

    for failure <- [{:error, "private-interaction-token"}, {:raise, "private-interaction-token"}] do
      FakeAdapter.fail(:defer, failure)

      log =
        capture_log(fn ->
          assert {:error, :acknowledgment_failed} = Dispatcher.handle(open, opts)
        end)

      refute log =~ "private-interaction-token"
      assert_receive {:discord, :defer, _}
      refute_receive {:discord, :edit_response, _}
      assert Repo.get!(Campaigns.Campaign, campaign.id).current_tick_number == 0
    end
  end

  test "response failure never retries the command", %{
    opts: opts,
    interaction: interaction,
    campaign: campaign
  } do
    FakeAdapter.fail(:edit_response, {:error, "private-interaction-token"})
    open = %{interaction | data: %{name: "tick", options: [%{type: 1, name: "open"}]}}
    log = capture_log(fn -> assert {:error, :response_failed} = Dispatcher.handle(open, opts) end)
    refute log =~ "private-interaction-token"
    assert Repo.get!(Campaigns.Campaign, campaign.id).current_tick_number == 1
    assert_receive {:discord, :defer, _}
    assert_receive {:discord, :edit_response, _}
    refute_receive {:discord, :defer, _}
  end

  test "ignores other applications, invalid envelopes and unsupported interaction kinds", %{
    opts: opts,
    interaction: interaction
  } do
    for bad <- [
          %{interaction | application_id: 222},
          %{interaction | id: nil},
          %{interaction | token: nil},
          %{interaction | type: 3},
          %{interaction | type: 4},
          %{interaction | type: 5}
        ] do
      assert :ignored = Dispatcher.handle(bad, opts)
    end

    refute_receive {:discord, _, _}
  end

  test "handler exceptions produce a private generic failure and redacted logs", %{
    opts: opts,
    interaction: interaction
  } do
    opts = Keyword.put(opts, :handler, AsyncWorlds.Discord.FailingHandler)

    log =
      capture_log(fn ->
        assert {:error, :failed} = Dispatcher.handle(interaction, opts)
      end)

    refute log =~ "private-command-content"
    refute log =~ "private-interaction-token"
    assert_receive {:discord, :defer, _}

    assert_receive {:discord, :edit_response,
                    {_,
                     "The command could not be completed. Please check its status before retrying."}}
  end

  test "production placeholder does not change state", %{
    opts: opts,
    interaction: interaction,
    campaign: campaign
  } do
    assert {:ok, _} = Dispatcher.handle(interaction, Keyword.delete(opts, :handler))
    assert Repo.get!(Campaigns.Campaign, campaign.id).current_tick_number == 0
  end
end
