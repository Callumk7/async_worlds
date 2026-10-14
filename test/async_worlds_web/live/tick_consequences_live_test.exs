defmodule AsyncWorldsWeb.TickConsequencesLiveTest do
  use AsyncWorldsWeb.ConnCase
  import Phoenix.LiveViewTest
  import AsyncWorlds.QuestFixtures
  alias AsyncWorlds.{Campaigns, Characters, Clocks, Deliveries, Quests, Repo, Ticks}
  alias AsyncWorlds.Quests.Submissions

  setup %{conn: conn} = context do
    {:ok, campaign} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "11001",
        dm_user_id: "22002",
        public_channel_id: "33003"
      })

    {:ok, player} =
      Characters.create_character(campaign, "22002", %{
        name: "Submitted player",
        discord_user_id: "44004"
      })

    {:ok, missing} =
      Characters.create_character(campaign, "22002", %{
        name: "Missing player",
        discord_user_id: "55005"
      })

    {:ok, clock} =
      Clocks.create_clock(
        campaign.id,
        %{
          name: "Hidden threat",
          segments: 4,
          background_rate: 1,
          visibility: :hidden,
          triggers: [%{type: :world_news, text: "Gate opened"}]
        },
        "dm"
      )

    choice =
      put_in(
        rolled(),
        ["outcomes", "success"],
        outcome("end", [
          %{"type" => "clock_delta", "clock_id" => clock.id, "delta" => 3},
          %{"type" => "set_flag", "key" => "secret", "flag" => flag()}
        ])
      )

    choice =
      if context[:invalidated_submission] do
        Map.put(choice, "conditions", [
          %{
            "type" => "character_flag",
            "key" => "ready",
            "flag_type" => "boolean",
            "value" => true
          }
        ])
      else
        choice
      end

    {:ok, revision} =
      Quests.create_quest(
        campaign,
        "22002",
        %{content_id: "quest", name: "Quest"},
        replace_choice(definition(), choice)
      )

    for character <- [player, missing],
        do: Quests.assign(campaign, "22002", character.id, revision.id)

    if context[:invalidated_submission] do
      {:ok, _} = Characters.set_flag(campaign, "22002", player.id, "ready", flag())
    end

    {:ok, tick} = Ticks.open_tick(campaign.id)
    {:ok, state} = Submissions.player_state("11001", "44004")
    {:ok, _} = Submissions.submit("11001", "44004", state.identity, "roll")

    if context[:invalidated_submission] do
      {:ok, _} = Characters.set_flag(campaign, "22002", player.id, "ready", flag(false))
    end

    {:ok, %{snapshot: snapshot}} = Ticks.close_tick(campaign.id, tick.id)
    {:ok, dice} = Ticks.record_quest_rolls(campaign.id, tick.id, snapshot.revision, fn -> 1 end)
    {:ok, payload} = Ticks.WorldResolver.resolve(snapshot, %{}, dice)
    {:ok, %{draft: draft}} = Ticks.put_draft(campaign.id, tick.id, snapshot.revision, payload)

    %{
      conn: log_in_dm(conn, campaign),
      campaign: campaign,
      player: player,
      missing: missing,
      tick: tick,
      clock: clock,
      draft: draft
    }
  end

  @tag invalidated_submission: true
  test "frozen ineligible submissions are invalidated, not missed choices", c do
    {:ok, snapshot} = Ticks.fetch_snapshot(c.campaign.id, c.tick.id)
    assert [%{"character_id" => id}] = snapshot.data["quest_inputs"]["invalidations"]
    assert id == c.player.id
    assert snapshot.data["quest_inputs"]["submissions"] == []

    {:ok, view, _} = live(c.conn, ~p"/ticks/#{c.tick.id}/review")
    row = "#player_consequences-#{c.player.id}"
    assert has_element?(view, row, "Invalidated choice · position unchanged")
    refute has_element?(view, row, "Missing choice")
    refute has_element?(view, "#{row} a[href='#quest_review-#{c.player.id}']")
    refute has_element?(view, "#quest_review-#{c.player.id}")
    assert has_element?(view, "#player_consequences-#{c.missing.id}", "Missing choice")

    [player | _] = AsyncWorlds.Ticks.ReviewProjection.players(c.draft.payload, snapshot)
    assert player.before == player.after
    refute player.submitted?
  end

  test "invalid previews do not claim the frozen roster has no players", c do
    {:ok, snapshot} = Ticks.fetch_snapshot(c.campaign.id, c.tick.id)
    assert snapshot.data["quest_inputs"]["characters"] != []

    {:ok, _} =
      Ticks.put_draft(
        c.campaign.id,
        c.tick.id,
        snapshot.revision,
        %{"clocks" => %{}, "world_news" => "invalid"},
        c.draft.id
      )

    {:ok, view, _} = live(c.conn, ~p"/ticks/#{c.tick.id}/review")
    assert has_element?(view, "#preview-error")
    assert has_element?(view, "#publish-tick[disabled]")
    assert has_element?(view, "#player-consequences-empty", "Player inspection is unavailable")
    refute has_element?(view, "#player-consequences-empty", "No players in the frozen tick")
  end

  test "player states and canonical downstream traces update without changing live state", c do
    {:ok, view, _} = live(c.conn, ~p"/ticks/#{c.tick.id}/review")
    assert has_element?(view, "#player_consequences-#{c.player.id}", "Submitted")
    assert has_element?(view, "#player_consequences-#{c.missing.id}", "Missing choice")
    assert has_element?(view, "#world-consequences")
    view |> form("#publish-form", publish: %{confirm: "true"}) |> render_change()
    assert has_element?(view, "#publish-form input[type=checkbox][checked]")

    view
    |> form("#quest-outcome-#{c.player.id}",
      quest: %{value: "success", reason: "Reviewed consequences"}
    )
    |> render_submit()

    refute has_element?(view, "#publish-form input[type=checkbox][checked]")
    assert has_element?(view, "#player_consequences-#{c.player.id}", "ending")
    assert has_element?(view, "#player-flags-#{c.player.id}", "secret")
    assert has_element?(view, "#player-downstream-#{c.player.id}", "Fired world_news")
    assert has_element?(view, "#clock-contributions-#{c.clock.id}", "Quest effect")
    assert has_element?(view, "#clock-contributions-#{c.clock.id}", "Background delta")
    assert has_element?(view, "#clock-contributions-#{c.clock.id}", "Completion / trigger")
    assert Repo.get!(AsyncWorlds.Clocks.Clock, c.clock.id).filled == 0
    assert Repo.get!(AsyncWorlds.Characters.Character, c.player.id).flags == %{}
    {:ok, draft} = Ticks.fetch_draft(c.campaign.id, c.tick.id)
    assert Enum.map(draft.payload["rolls"], & &1["value"]) == [1, 1, 1]

    view
    |> form("#draft-clock-#{c.clock.id}",
      delta: %{amount: "0", reason: "Replace background only"}
    )
    |> render_submit()

    assert has_element?(view, "#clock-result-#{c.clock.id}", "3/4")
    assert has_element?(view, "#clock-contributions-#{c.clock.id}", "Quest effect")
    refute has_element?(view, "#player-downstream-#{c.player.id}", "Fired world_news")
  end

  test "exact chunk boundaries and recipient privacy match stored publication and outbox", c do
    {:ok, view, _} = live(c.conn, ~p"/ticks/#{c.tick.id}/review")

    view
    |> form("#quest-outcome-#{c.player.id}",
      quest: %{value: "success", reason: "Privacy with hidden flags"}
    )
    |> render_submit()

    assert has_element?(view, "#player-flags-#{c.player.id}", "secret")
    narration = String.duplicate("Private 🌍", 218)

    view
    |> form("#quest-narration-#{c.player.id}",
      quest: %{value: narration, reason: "Long narration"}
    )
    |> render_submit()

    {:ok, draft} = Ticks.fetch_draft(c.campaign.id, c.tick.id)
    {:ok, outputs} = Ticks.preview_draft(c.campaign.id, c.tick.id, draft.id)
    messages = Enum.filter(outputs["players"], &(&1["character_id"] == c.player.id))
    assert length(messages) > 1

    for {message, index} <- Enum.with_index(messages, 1) do
      selector = "#private_preview-players-44004-#{c.player.id}-owner-chunk-#{index} pre"
      assert has_element?(view, selector)

      assert view |> element(selector) |> render() |> LazyHTML.from_fragment() |> LazyHTML.text() ==
               message["content"]
    end

    missing_selector = "#private-preview [data-character-id='#{c.missing.id}']"
    refute has_element?(view, missing_selector, "Private 🌍")
    refute has_element?(view, missing_selector, "Hidden threat")
    refute has_element?(view, "#public-preview", "Private 🌍")
    refute has_element?(view, "#public-preview", "Hidden threat")
    refute has_element?(view, "#private-preview [data-character-id='#{c.player.id}']", "secret")
    view |> form("#publish-form", publish: %{confirm: "true"}) |> render_submit()
    assert_redirect(view, ~p"/dashboard")
    {:ok, publication} = Ticks.fetch_publication(c.campaign.id, c.tick.id)
    assert publication.outputs == outputs
    deliveries = Deliveries.list_deliveries(c.campaign.id)

    for message <- messages do
      assert Enum.any?(
               deliveries,
               &(&1.recipient_id == message["recipient_id"] && &1.content == message["content"])
             )
    end
  end

  test "forged fresh tokens cannot edit or publish unseen revisions; stale tabs require reload",
       c do
    {:ok, view, _} = live(c.conn, ~p"/ticks/#{c.tick.id}/review")

    {:ok, %{draft: fresh}} =
      Ticks.edit_draft(
        c.campaign.id,
        c.tick.id,
        c.draft.id,
        %{type: "world_news", text: ["Unseen revision"]},
        "22002",
        "Other tab"
      )

    render_submit(view, "publish", %{"publish" => %{"draft_id" => fresh.id, "confirm" => "true"}})
    assert has_element?(view, "#stale-review")
    refute has_element?(view, "#public-preview", "Unseen revision")

    render_submit(view, "edit_news", %{
      "news" => %{
        "draft_id" => fresh.id,
        "mode" => "override",
        "text" => "Forged",
        "reason" => "Attempt"
      }
    })

    assert {:ok, ^fresh} = Ticks.fetch_draft(c.campaign.id, c.tick.id)
    view |> element("#refresh-review") |> render_click()
    assert has_element?(view, "#public-preview", "Unseen revision")
    refute has_element?(view, "#publish-form input[type=checkbox][checked]")
    {:ok, other, _} = live(c.conn, ~p"/ticks/#{c.tick.id}/review")
    view |> form("#publish-form", publish: %{confirm: "true"}) |> render_submit()
    count = length(Deliveries.list_deliveries(c.campaign.id))
    other |> form("#publish-form", publish: %{confirm: "true"}) |> render_submit()
    assert length(Deliveries.list_deliveries(c.campaign.id)) == count
    assert {:ok, %{status: :published}} = Ticks.fetch_tick(c.campaign.id, c.tick.id)
  end
end
