defmodule AsyncWorlds.Discord.CharacterCommandTest do
  use AsyncWorlds.DataCase, async: false
  alias AsyncWorlds.{Campaigns, Characters}
  alias AsyncWorlds.Discord.{Commands, Dispatcher, FakeAdapter, NostrumAdapter}

  setup do
    start_supervised!({FakeAdapter, owner: self()})

    {:ok, campaign} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "123",
        dm_user_id: "456",
        public_channel_id: "789"
      })

    {:ok, character} =
      Characters.create_character(campaign, "456", %{
        name: "Rook",
        discord_user_id: "999",
        flags: %{
          "secret" => %{"type" => "string", "value" => "classified", "player_visible" => false},
          "debt" => %{"type" => "integer", "value" => 2, "player_visible" => true}
        }
      })

    {:ok, other} =
      Characters.create_character(campaign, "456", %{name: "Someone else", discord_user_id: "998"})

    %{
      character: character,
      other: other,
      opts: [adapter: FakeAdapter, guild_id: "123", application_id: "111"]
    }
  end

  defp interaction do
    %{
      type: 2,
      id: System.unique_integer([:positive]),
      application_id: 111,
      guild_id: 123,
      member: %{user_id: 999},
      user: %{id: 998},
      token: "test-only",
      data: %{name: "character"}
    }
  end

  test "character uses authenticated member only and replies privately with visible facts", c do
    assert {:ok, "Rook\ndebt: 2" = content} = Dispatcher.handle(interaction(), c.opts)
    assert_receive {:discord, :defer, _}
    assert_receive {:discord, :edit_response, {_, ^content}}
    assert NostrumAdapter.followup_data(content).flags == 64
    refute content =~ "secret"
    refute content =~ "classified"
    refute_receive {:discord, :send_public, _}
    refute_receive {:discord, :send_private, _}
    assert {:ok, :character, :player} = Commands.route(%{name: "character"})
  end

  test "supplied character IDs and missing/invalid authenticated identity never select another owner",
       c do
    for options <- [
          [%{name: "character_id", type: 4, value: c.other.id}],
          [%{name: "user_id", type: 3, value: "998"}]
        ] do
      forged = put_in(interaction(), [:data, :options], options)
      assert {:error, :unknown_command} = Dispatcher.handle(forged, c.opts)
    end

    for member <- [nil, %{}, %{user_id: "0999"}, %{user_id: "18446744073709551616"}] do
      assert {:error, :unauthorized} =
               Dispatcher.handle(Map.put(interaction(), :member, member), c.opts)
    end

    assert {:error, :not_found} =
             Dispatcher.handle(put_in(interaction(), [:member, :user_id], 997), c.opts)

    assert {:error, :unauthorized} =
             Dispatcher.handle(Map.put(interaction(), :guild_id, 124), c.opts)

    refute_receive {:discord, :send_public, _}
  end
end
