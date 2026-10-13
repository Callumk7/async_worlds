defmodule AsyncWorlds.Ticks.HistoryTest do
  use AsyncWorlds.DataCase, async: true
  import AsyncWorlds.HistoryFixtures
  alias AsyncWorlds.{Campaigns, Deliveries, Repo, Ticks}
  alias AsyncWorlds.Ticks.History

  test "only published records are listed, in stable bounded pages" do
    campaign = history_campaign()
    for number <- 1..21, do: legacy_publication(campaign, number)
    Repo.update!(Ecto.Changeset.change(campaign, current_tick_number: 21))
    {:ok, _} = Ticks.open_tick(campaign.id)
    other = history_campaign("11002", "22003")
    legacy_publication(other, 1)

    assert {:ok, first} = History.list("11001", "22002")
    assert length(first.items) == 20
    assert first.more?
    assert Enum.map(first.items, & &1.number) == Enum.to_list(21..2//-1)
    assert {:ok, second} = History.list("11001", "22002", 2)
    assert [%{number: 1}] = second.items
    refute second.more?
    assert {:ok, %{items: []}} = History.list("11001", "22002", 3)
    assert {:error, :invalid_page} = History.list("11001", "22002", 0)
  end

  test "legacy history uses saved messages, not a current renderer or current labels" do
    campaign = history_campaign()
    tick = legacy_publication(campaign, 1)
    assert {:ok, history} = History.fetch("11001", "22002", tick.id)
    assert history.world_news == "Legacy approved news 1"
    assert history.sections["results"].items == []
    assert history.sections["rolls"].items == []

    assert [%{content: "Legacy stored message 1", delivery: nil, chunk: 1}] =
             history.sections["messages"].items
  end

  test "approved results and distinct audit sources are saved; mutable delivery status is separate" do
    c = publish_history_quest(history_campaign())
    assert {:ok, history} = History.fetch("11001", "22002", c.tick.id)
    assert history.publication.draft_id == c.draft.id
    assert history.input_revision == c.draft.input_revision

    assert [%{"text" => "Saved private narration", "outcome" => "success"} = result] =
             history.sections["results"].items

    assert result["input"]["revision_id"] == c.revision.id
    assert length(history.sections["rolls"].items) == 3
    assert [edit] = history.sections["reviews"].items
    assert edit.previous_draft_id == c.initial.id
    assert edit.draft_id == c.draft.id
    assert edit.reason == "Preserve this correction"
    assert [%{operation: "assign", tick_id: tick_id}] = history.sections["interventions"].items
    assert tick_id == c.tick.id

    assert [%{clock_id: clock_id, before: %{"filled" => 0}, after: %{"filled" => 2}}] =
             history.sections["audits"].items

    assert clock_id == c.clock.id

    private = Enum.find(history.sections["messages"].items, &(&1.audience == "players"))
    assert private.recipient == "44004"
    assert private.delivery
    refute private.content =~ "private_fact"

    opening =
      Enum.find(Deliveries.list_deliveries(c.campaign.id), &String.starts_with?(&1.key, "open:"))

    if opening,
      do:
        refute(
          Enum.any?(
            history.sections["messages"].items,
            &(&1.delivery && &1.delivery.id == opening.id)
          )
        )

    Repo.update!(
      Ecto.Changeset.change(private.delivery,
        status: :failed,
        last_error: "secret token must not be rendered"
      )
    )

    assert {:ok, refreshed} = History.fetch("11001", "22002", c.tick.id)
    assert refreshed.sections["results"] == history.sections["results"]
    refreshed_message = Enum.find(refreshed.sections["messages"].items, &(&1.key == private.key))
    assert refreshed_message.content == private.content
    assert refreshed_message.delivery.status == :failed
    assert {:ok, _} = Deliveries.retry_delivery(c.campaign.id, private.delivery.id, 0)
    assert {:ok, retried} = History.fetch("11001", "22002", c.tick.id)

    assert Enum.find(retried.sections["messages"].items, &(&1.key == private.key)).delivery.status ==
             :pending
  end

  test "detail sections paginate independently with bounded SQL audits and saved message chunks" do
    campaign = history_campaign()
    results = for id <- 1..21, do: %{"character_id" => id, "text" => "Saved result #{id}"}
    messages = for id <- 1..21, do: %{"recipient_id" => "33003", "content" => "Saved chunk #{id}"}

    tick =
      legacy_publication(campaign, 1,
        payload: %{"private_results" => results},
        outputs: %{"public" => messages}
      )

    {:ok, character} =
      AsyncWorlds.Characters.create_character(campaign, "22002", %{name: "Audited character"})

    for id <- 1..21 do
      Repo.insert!(%AsyncWorlds.Quests.Intervention{
        campaign_id: campaign.id,
        character_id: character.id,
        tick_id: tick.id,
        actor_id: "22002",
        operation: "move",
        reason: "Audit #{id}",
        after: %{}
      })
    end

    assert {:ok, first} = History.fetch("11001", "22002", tick.id)

    for section <- ["results", "messages", "interventions"] do
      assert length(first.sections[section].items) == 20
      assert first.sections[section].more?
    end

    assert hd(first.sections["results"].items)["historical_character"] ==
             "Character #1 (historical name not recorded)"

    assert {:ok, second} =
             History.fetch("11001", "22002", tick.id, %{"messages" => 2, "interventions" => 2})

    assert [%{chunk: 21, content: "Saved chunk 21"}] = second.sections["messages"].items
    assert [%{reason: "Audit 21"}] = second.sections["interventions"].items
    assert second.sections["results"] == first.sections["results"]
    refute second.sections["messages"].more?
  end

  test "domain operations authorize current DM and reject forged, nonpublished and foreign IDs" do
    campaign = history_campaign()
    tick = publish_world(campaign)
    other = history_campaign("11002", "22003")
    foreign = publish_world(other)
    {:ok, open} = Ticks.open_tick(campaign.id)
    assert {:error, :unauthorized} = History.list("11001", "44004")
    assert {:error, :unauthorized} = History.fetch("11001", "44004", tick.id)

    for id <- [foreign.id, open.id, 999_999, "not-an-id"] do
      assert {:error, :not_found} = History.fetch("11001", "22002", id)
    end

    assert {:error, :not_found} = History.fetch("11001", "22002", tick.id, %{"messages" => -1})

    {:ok, _} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "11001",
        dm_user_id: "55555",
        public_channel_id: "33003"
      })

    assert {:error, :unauthorized} = History.fetch("11001", "22002", tick.id)
    assert {:error, :unauthorized} = History.list("11001", "22002")
  end
end
