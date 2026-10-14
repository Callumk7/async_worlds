defmodule AsyncWorlds.Discord.LocationCommandsTest do
  use AsyncWorlds.DataCase, async: false

  alias AsyncWorlds.{Campaigns, Characters, Locations}
  alias AsyncWorlds.Discord.{Commands, DebugSessions, Dispatcher, FakeAdapter, NostrumAdapter}

  setup do
    start_supervised!({FakeAdapter, owner: self()})

    {:ok, campaign} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "123",
        dm_user_id: "456",
        public_channel_id: "789"
      })

    %{
      campaign: campaign,
      scope: %{campaign: campaign, discord_user_id: "456"},
      opts: [adapter: FakeAdapter, guild_id: "123", application_id: "111"]
    }
  end

  defp list_data, do: %{name: "location", options: [%{name: "list", type: 1}]}

  defp show_data(id),
    do: %{
      name: "location",
      options: [
        %{name: "show", type: 1, options: [%{name: "location", type: 3, value: to_string(id)}]}
      ]
    }

  defp interaction(data, user \\ 999) do
    %{
      type: 2,
      id: System.unique_integer([:positive]),
      application_id: 111,
      guild_id: 123,
      member: %{user_id: user},
      token: "test-only",
      data: data
    }
  end

  test "catalogue registers both commands for members with a required string ID" do
    assert {:ok, :location_list, :member} = Commands.route(list_data())
    assert {:ok, {:location_show, "123"}, :member} = Commands.route(show_data(123))
    definition = Enum.find(Commands.definitions(), &(&1.name == "location"))
    assert [list, show] = definition.options
    assert list.name == "list"

    assert [%{name: "location", type: 3, required: true}] =
             Enum.map(show.options, &Map.take(&1, [:name, :type, :required]))

    refute Map.has_key?(definition, :permission)
    refute Map.has_key?(definition, :default_member_permissions)
  end

  test "members without characters and DMs can read names and descriptions privately", c do
    {:ok, location} =
      Locations.create_location(c.scope, %{name: "Guild", description: "First\nSecond @everyone"})

    for user <- [999, 456] do
      assert {:ok, list} = Dispatcher.handle(interaction(list_data(), user), c.opts)
      assert list =~ "#{location.id} · Guild"
      refute list =~ "First"
      assert {:ok, detail} = Dispatcher.handle(interaction(show_data(location.id), user), c.opts)
      assert detail == "Guild (ID #{location.id})\nFirst\nSecond @everyone"
      assert_receive {:discord, :defer, _}
      assert_receive {:discord, :edit_response, {_, ^list}}
      assert_receive {:discord, :defer, _}
      assert_receive {:discord, :edit_response, {_, ^detail}}
      assert NostrumAdapter.followup_data(detail).flags == 64

      assert detail
             |> NostrumAdapter.followup_data()
             |> Nostrum.Api.Helpers.prepare_allowed_mentions() == %{
               content: detail,
               flags: 64,
               allowed_mentions: %{parse: []}
             }
    end

    refute_receive {:discord, :send_public, _}
    refute_receive {:discord, :send_private, _}
  end

  test "empty list and absent description have friendly responses", c do
    assert {:ok, "No locations yet in this campaign."} =
             Dispatcher.handle(interaction(list_data()), c.opts)

    {:ok, location} = Locations.create_location(c.scope, %{name: "Guild"})
    assert {:ok, detail} = Dispatcher.handle(interaction(show_data(location.id)), c.opts)
    assert detail =~ "No description yet."
  end

  test "foreign, deleted and malformed location IDs never reveal another campaign", c do
    {:ok, other} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "124",
        dm_user_id: "457",
        public_channel_id: "790"
      })

    {:ok, foreign} =
      Locations.create_location(%{campaign: other, discord_user_id: "457"}, %{
        name: "Foreign",
        description: "Secret"
      })

    {:ok, location} = Locations.create_location(c.scope, %{name: "Deleted"})
    {:ok, _} = Locations.delete_location(c.scope, location.id)

    for id <- [foreign.id, location.id, "bad", "9223372036854775808"] do
      assert {:ok, "Location not found in this campaign. Use /location list to find its ID."} =
               Dispatcher.handle(interaction(show_data(id)), c.opts)
    end

    assert {:ok, "No locations yet in this campaign."} =
             Dispatcher.handle(interaction(list_data()), c.opts)

    assert {:ok, []} = Locations.list_campaign_locations("123")
    assert {:error, :not_found} = Locations.get_campaign_location("123", foreign.id)
  end

  test "rejects unknown subcommands, extra fields, missing arguments and duplicate IDs" do
    for data <- [
          %{name: "location"},
          %{name: "location", options: [%{name: "delete", type: 1}]},
          %{name: "location", options: [%{name: "show", type: 1}]},
          put_in(list_data(), [:options], [
            %{name: "list", type: 1, options: [%{name: "guild_id", type: 3, value: "124"}]}
          ]),
          %{
            name: "location",
            options: [%{name: "show", type: 1, options: [%{name: "location", type: 4, value: 1}]}]
          },
          %{
            name: "location",
            options: [
              %{
                name: "show",
                type: 1,
                options: [
                  %{name: "location", type: 3, value: "1"},
                  %{name: "location", type: 3, value: "2"}
                ]
              }
            ]
          }
        ] do
      assert {:error, :unknown_command} = Commands.route(data)
    end
  end

  test "requires the configured guild and authenticated member, not top-level user", c do
    for extra <- [
          %{guild_id: 124},
          %{guild_id: nil},
          %{member: nil, user: %{id: 999}},
          %{member: %{user_id: "0999"}}
        ] do
      assert {:error, :unauthorized} =
               Dispatcher.handle(Map.merge(interaction(list_data()), extra), c.opts)
    end

    assert :ignored =
             Dispatcher.handle(Map.put(interaction(list_data()), :application_id, 222), c.opts)
  end

  test "campaign reads project public fields only and do not use DM debug subjects", c do
    {:ok, location} = Locations.create_location(c.scope, %{name: "Guild", description: "Notes"})
    assert {:ok, [%{id: location.id, name: "Guild"}]} == Locations.list_campaign_locations("123")

    assert {:ok, %{id: location.id, name: "Guild", description: "Notes"}} ==
             Locations.get_campaign_location("123", location.id)

    {:ok, character} = Characters.create_character(c.campaign, "456", %{name: "Tester"})
    {:ok, _} = DebugSessions.transition("123", "456", {:player, character.id})
    assert {:ok, content} = Dispatcher.handle(interaction(list_data(), 456), c.opts)
    refute content =~ "Testing as"
    assert content =~ "Guild"
    Repo.delete!(character)
    assert {:ok, after_deletion} = Dispatcher.handle(interaction(list_data(), 456), c.opts)
    assert after_deletion =~ "Guild"
  end

  test "long lists and descriptions use private followups without losing Unicode", c do
    description = String.duplicate("Lore 🌍\n", 500)

    {:ok, location} =
      Locations.create_location(c.scope, %{name: "Guild", description: description})

    assert {:ok, content} = Dispatcher.handle(interaction(show_data(location.id)), c.opts)
    chunks = AsyncWorlds.Discord.Content.chunks(content)
    [first | rest] = chunks
    assert_receive {:discord, :edit_response, {_, ^first}}

    for chunk <- rest do
      assert_receive {:discord, :followup_response, {_, ^chunk}}
      assert String.valid?(chunk)
      assert NostrumAdapter.followup_data(chunk).flags == 64
    end

    assert Enum.join(chunks) == "Guild (ID #{location.id})\n" <> description

    for i <- 1..15,
        do: Locations.create_location(c.scope, %{name: "#{i}-" <> String.duplicate("x", 190)})

    assert {:ok, list} = Dispatcher.handle(interaction(list_data()), c.opts)
    assert_receive {:discord, :edit_response, _}
    assert_receive {:discord, :followup_response, _}
    assert list =~ "15-"
    refute_receive {:discord, :send_public, _}
  end
end
