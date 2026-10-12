defmodule AsyncWorlds.Ticks.DebugDeliveryTest do
  use AsyncWorlds.DataCase, async: true
  import AsyncWorlds.QuestFixtures
  alias AsyncWorlds.{Campaigns, Characters, Deliveries, PlayerAccess, Quests, Ticks}
  alias AsyncWorlds.Discord.DebugSessions
  alias AsyncWorlds.Quests.Submissions
  alias AsyncWorlds.Ticks.{Output, PlayerDelivery, WorldResolver}

  test "accountless characters receive frozen labelled results and copies do not redirect owners" do
    {:ok, campaign} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "123",
        dm_user_id: "456",
        public_channel_id: "789"
      })

    {:ok, revision} =
      Quests.create_quest(campaign, "456", %{content_id: "test", name: "Test"}, definition())

    characters =
      for {name, owner} <- [{"A", nil}, {"B", nil}, {"Linked", "999"}, {"DM owned", "456"}] do
        {:ok, character} =
          Characters.create_character(campaign, "456", %{name: name, discord_user_id: owner})

        {:ok, _} = Quests.assign(campaign, "456", character.id, revision.id)
        character
      end

    {:ok, tick} = Ticks.open_tick(campaign.id)

    for character <- characters do
      {:ok, _} = DebugSessions.transition("123", "456", {:player, character.id})
      {:ok, context} = PlayerAccess.context(campaign, "456")
      {:ok, state} = Submissions.player_state("123", context.access)
      {:ok, _} = Submissions.submit("123", context.access, state.identity, "loop")
    end

    {:ok, _} = DebugSessions.transition("123", "456", {:messages, true})
    {:ok, %{snapshot: snapshot}} = Ticks.close_tick(campaign.id, tick.id)
    assert snapshot.schema_version == 3
    assert WorldResolver.valid_snapshot?(snapshot)
    routes = snapshot.data["player_delivery"]["routes"]
    assert length(routes) == 5
    assert Enum.count(routes, &(&1["audience"] == "dm_copy")) == 1
    assert Enum.count(routes, &(&1["recipient_id"] == "999")) == 1
    {:ok, payload} = WorldResolver.resolve(snapshot)
    {:ok, %{draft: draft}} = Ticks.put_draft(campaign.id, tick.id, snapshot.revision, payload)
    {:ok, preview} = Ticks.preview_draft(campaign.id, tick.id, draft.id)
    assert preview == Output.render(payload, snapshot.data["campaign"])
    assert Enum.any?(preview["players"], &String.starts_with?(&1["content"], "Player: A"))
    assert Enum.any?(preview["players"], &String.starts_with?(&1["content"], "Player: B"))

    assert Enum.any?(
             preview["players"],
             &String.starts_with?(&1["content"], "Player copy: Linked")
           )

    {:ok, _} = DebugSessions.transition("123", "456", :off)
    assert {:ok, published} = Ticks.publish_tick(campaign.id, tick.id, draft.id)
    assert published.status == :published
    assert {:error, :already_published} = Ticks.publish_tick(campaign.id, tick.id, draft.id)
    deliveries = Deliveries.list_deliveries(campaign.id)
    assert length(Enum.uniq_by(deliveries, & &1.key)) == length(deliveries)

    for message <- preview["players"] do
      assert Enum.any?(
               deliveries,
               &(&1.recipient_id == message["recipient_id"] and &1.content == message["content"])
             )
    end

    bad = put_in(snapshot.data["player_delivery"]["routes"], [])
    refute WorldResolver.valid_snapshot?(%{snapshot | data: bad})
  end

  test "route defaults retain linked owners and deduplicate DM copies" do
    chars = [
      %{"id" => 1, "name" => "A", "discord_user_id" => "999"},
      %{"id" => 2, "name" => "DM", "discord_user_id" => "456"}
    ]

    campaign = %{"dm_user_id" => "456"}
    assert length(PlayerDelivery.freeze(chars, campaign, false)["routes"]) == 2
    assert length(PlayerDelivery.freeze(chars, campaign, true)["routes"]) == 3
  end
end
