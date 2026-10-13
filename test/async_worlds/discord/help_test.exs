defmodule AsyncWorlds.Discord.HelpTest do
  use AsyncWorlds.DataCase, async: false

  alias AsyncWorlds.{Campaigns, Characters, Deliveries, Ticks}
  alias AsyncWorlds.Discord.{Commands, DebugSessions, Dispatcher, FakeAdapter, Help}

  setup do
    start_supervised!({FakeAdapter, owner: self()})

    {:ok, campaign} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "123",
        dm_user_id: "456",
        public_channel_id: "789"
      })

    %{campaign: campaign, opts: [adapter: FakeAdapter, guild_id: "123", application_id: "111"]}
  end

  test "players without characters receive private help, with no DM commands or side effects",
       c do
    assert {:ok, content} = invoke(c, "999")
    assert content =~ "/help — List the commands available to you"
    assert content =~ "/quest — View your private quest and choose an action"
    assert content =~ "/submission"
    refute content =~ "/tick"
    refute content =~ "/admin"
    refute content =~ "/debug"
    assert_receive {:discord, :defer, _}
    assert_receive {:discord, :edit_response, {_, ^content}}
    refute_receive {:discord, :send_public, _}
    refute_receive {:discord, :send_private, _}
    assert is_nil(Ticks.active_tick(c.campaign.id))
    assert Deliveries.list_deliveries(c.campaign.id) == []
  end

  test "DMs see player, DM and debug commands with full subcommand paths", c do
    assert {:ok, content} = invoke(c, "456")
    assert content =~ "/character"
    assert content =~ "/tick open — Open a new tick"
    assert content =~ "/tick close — Close submissions and resolve the tick"
    assert content =~ "/admin"
    assert content =~ "/debug player character:<character>"
    assert content =~ "/debug messages enabled:<enabled>"
    assert content =~ "Debug controls (real DM)"
  end

  test "debug player mode hides DM-role commands but keeps real-DM debug controls", c do
    {:ok, character} = Characters.create_character(c.campaign, "456", %{name: "Tester"})
    {:ok, _} = DebugSessions.transition("123", "456", {:player, character.id})

    assert {:ok, content} = invoke(c, "456")
    assert content =~ "Testing as Tester"
    assert content =~ "/quest"
    assert content =~ "/debug dm"
    assert content =~ "/debug off"
    refute content =~ "/tick"
    refute content =~ "/admin"

    {:ok, _} = DebugSessions.transition("123", "456", :dm)
    assert {:ok, content} = invoke(c, "456", 2)
    assert content =~ "/tick open"
  end

  test "registration descriptions and actual routing permissions determine help visibility", c do
    player_help = Help.render(%{campaign: c.campaign, user_id: "999", role: :player})
    dm_help = Help.render(%{campaign: c.campaign, user_id: "456", role: :dm})

    for definition <- Commands.definitions(), {path, data, description} <- samples(definition) do
      assert {:ok, _, permission} = Commands.route(data)
      assert dm_help =~ "/#{path}"
      assert dm_help =~ description

      if permission == :player do
        assert player_help =~ "/#{path}"
        assert player_help =~ description
      else
        refute player_help =~ "/#{path}"
      end
    end

    # Internal metadata must never be sent to Discord, including nested options.
    for definition <- Commands.definitions(), do: assert_discord_definition(definition)
  end

  test "catalogue additions, edits, removals and nested groups need no help-specific changes",
       c do
    context = %{campaign: c.campaign, user_id: "999", role: :player}

    added = %{
      name: "future",
      description: "Future functionality",
      type: 1,
      permission: :player,
      options: [
        %{
          name: "group",
          description: "Group",
          type: 2,
          options: [
            %{name: "inspect", description: "New inspection", type: 1},
            %{name: "manage", description: "Restricted management", type: 1, permission: :dm}
          ]
        }
      ]
    }

    updated =
      Commands.catalogue()
      |> Enum.reject(&(&1.name == "result"))
      |> Enum.map(fn
        %{name: "quest"} = entry -> %{entry | description: "Updated quest description"}
        entry -> entry
      end)

    content = Help.render(context, updated ++ [added])
    assert content =~ "/future group inspect — New inspection"
    assert content =~ "/quest — Updated quest description"
    refute content =~ "/future group manage"
    refute content =~ "/result"
    refute content =~ "View your private quest and choose an action"
    assert Help.render(context, []) == ""
  end

  test "help rejects arguments and retains the dispatcher's trusted guild identity checks", c do
    assert {:error, :unknown_command} = Commands.route(%{name: "help", options: [%{}]})

    for {extra, id} <-
          Enum.with_index([%{guild_id: 321}, %{member: nil}, %{member: %{user_id: "0999"}}], 1) do
      assert {:error, :unauthorized} = invoke(c, "999", id, extra)

      assert_receive {:discord, :edit_response,
                      {_, "This command is not available to you in this server."}}
    end
  end

  test "debug status uses the same generated command listing", c do
    {:ok, context} = AsyncWorlds.PlayerAccess.context(c.campaign, "456")
    assert {:ok, %{content: content}} = Commands.execute({:debug, {:status, 0}}, context)
    assert content =~ Help.render(context)
  end

  defp invoke(c, user, id \\ 1, extra \\ %{}) do
    interaction = %{
      type: 2,
      id: id,
      application_id: 111,
      guild_id: 123,
      member: %{user_id: user},
      token: "private-token",
      data: %{name: "help"}
    }

    Dispatcher.handle(Map.merge(interaction, extra), c.opts)
  end

  defp samples(definition) do
    subcommands = Enum.filter(Map.get(definition, :options, []), &(&1.type in [1, 2]))

    if subcommands == [] do
      options =
        definition
        |> Map.get(:options, [])
        |> Enum.filter(&Map.get(&1, :required, false))
        |> Enum.map(fn option ->
          %{
            name: option.name,
            type: option.type,
            value: if(option.type == 5, do: true, else: "1")
          }
        end)

      [
        {definition.name, %{name: definition.name, type: definition.type, options: options},
         definition.description}
      ]
    else
      for child <- subcommands, {path, data, description} <- samples(child) do
        {definition.name <> " " <> path,
         %{name: definition.name, type: definition.type, options: [data]}, description}
      end
    end
  end

  defp assert_discord_definition(definition) do
    refute Map.has_key?(definition, :permission)
    refute Map.has_key?(definition, :command)
    for option <- Map.get(definition, :options, []), do: assert_discord_definition(option)
  end
end
