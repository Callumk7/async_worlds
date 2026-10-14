defmodule AsyncWorldsWeb.QuestPublicationLiveTest do
  use AsyncWorldsWeb.ConnCase
  use Oban.Testing, repo: AsyncWorlds.Repo
  import Phoenix.LiveViewTest
  import AsyncWorlds.QuestFixtures
  alias AsyncWorlds.{Campaigns, Characters, Clocks, Quests, Ticks}
  alias AsyncWorlds.Quests.Submissions
  alias AsyncWorlds.Workers.ResolveTick

  setup %{conn: conn} do
    {:ok, campaign} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "11001",
        dm_user_id: "22002",
        public_channel_id: "33003"
      })

    {:ok, character} =
      Characters.create_character(campaign, "22002", %{
        name: "Player",
        discord_user_id: "44004"
      })

    {:ok, revision} =
      Quests.create_quest(campaign, "22002", %{content_id: "quest", name: "Quest"}, definition())

    {:ok, _} = Quests.assign(campaign, "22002", character.id, revision.id)

    %{
      conn: log_in_dm(conn, campaign),
      campaign: campaign,
      character: character,
      revision: revision
    }
  end

  test "reachable selected reroll, outcome/clear, player narration and stale controls", c do
    {:ok, revision} =
      Quests.append_revision(
        c.campaign,
        "22002",
        c.revision.quest_id,
        replace_choice(definition(), rolled())
      )

    {:ok, _} = Quests.swap(c.campaign, "22002", c.character.id, revision.id)
    {:ok, tick} = Ticks.open_tick(c.campaign.id)
    {:ok, state} = Submissions.player_state("11001", "44004")
    {:ok, _} = Submissions.submit("11001", "44004", state.identity, "roll")
    {:ok, %{snapshot: snapshot}} = Ticks.close_tick(c.campaign.id, tick.id)
    {:ok, _} = Ticks.record_quest_rolls(c.campaign.id, tick.id, snapshot.revision, fn -> 1 end)

    :ok =
      perform_job(ResolveTick, %{
        campaign_id: c.campaign.id,
        tick_id: tick.id,
        input_revision: snapshot.revision
      })

    {:ok, view, _} = live(c.conn, ~p"/ticks/#{tick.id}/review")
    assert has_element?(view, "#quest-review")
    assert has_element?(view, "#private-preview", "44004")
    assert has_element?(view, "#quest-die-#{c.character.id}-0")

    view
    |> form("#quest-die-#{c.character.id}-0", die: %{reason: "Review die"})
    |> render_submit()

    {:ok, [audit]} = Ticks.list_review_edits(c.campaign.id, tick.id)
    assert audit.operation["type"] == "reroll"
    assert audit.operation["old_value"] == 1
    {:ok, rerolled} = Ticks.fetch_draft(c.campaign.id, tick.id)
    assert Enum.map(tl(rerolled.payload["rolls"]), & &1["value"]) == [1, 1]

    assert has_element?(
             view,
             "#player-effects-#{c.character.id}",
             "Recorded die: #{audit.operation["new_value"]}"
           )

    view
    |> form("#quest-outcome-#{c.character.id}",
      quest: %{value: "success", reason: "Force success"}
    )
    |> render_submit()

    {:ok, d} = Ticks.fetch_draft(c.campaign.id, tick.id)
    assert hd(d.payload["private_results"])["outcome"] == "success"

    view
    |> form("#quest-narration-#{c.character.id}",
      quest: %{value: "Private approved text", reason: "Narrate"}
    )
    |> render_submit()

    assert has_element?(view, "#private-preview", "Private approved text")

    view
    |> form("#quest-narration-#{c.character.id}", quest: %{value: "", reason: "Restore"})
    |> render_submit()

    refute has_element?(view, "#private-preview", "Private approved text")

    view
    |> form("#quest-outcome-#{c.character.id}", quest: %{value: "", reason: "Restore dice"})
    |> render_submit()

    {:ok, d} = Ticks.fetch_draft(c.campaign.id, tick.id)

    {:ok, _} =
      Ticks.edit_draft(
        c.campaign.id,
        tick.id,
        d.id,
        %{type: "world_news", text: []},
        "22002",
        "Another tab"
      )

    view
    |> form("#quest-narration-#{c.character.id}", quest: %{value: "Stale text", reason: "Stale"})
    |> render_submit()

    assert has_element?(view, "#stale-review")
    assert has_element?(view, "#quest-narration-#{c.character.id} fieldset[disabled]")
    view |> element("#refresh-review") |> render_click()
    refute has_element?(view, "#stale-review")
    view |> form("#publish-form", publish: %{confirm: "true"}) |> render_submit()
    assert_redirect(view, ~p"/dashboard")
  end

  for kind <- [:submission, :trigger, :world_only] do
    @kind kind
    test "#{@kind} publication has the appropriate outcome", c do
      {:ok, tick} = Ticks.open_tick(c.campaign.id)

      case @kind do
        :submission ->
          {:ok, state} = Submissions.player_state("11001", "44004")
          {:ok, _} = Submissions.submit("11001", "44004", state.identity, "loop")

        :trigger ->
          {:ok, clock} =
            Clocks.create_clock(c.campaign.id, %{name: "Quest trigger", segments: 4}, "dm")

          {:ok, _} =
            Quests.configure_clock_triggers(c.campaign, "22002", clock.id, [
              %{type: :unlock_quest, character_id: c.character.id, quest_id: c.revision.quest_id}
            ])

        :world_only ->
          :ok
      end

      {:ok, %{snapshot: snapshot}} = Ticks.close_tick(c.campaign.id, tick.id)

      assert :ok =
               perform_job(ResolveTick, %{
                 campaign_id: c.campaign.id,
                 tick_id: tick.id,
                 input_revision: snapshot.revision
               })

      assert snapshot.schema_version == 3
      {:ok, view, _} = live(c.conn, ~p"/ticks/#{tick.id}/review")

      if @kind == :submission do
        refute has_element?(view, "#quest-outcome-#{c.character.id}")
        refute has_element?(view, "#quest-die-#{c.character.id}-0")
        assert has_element?(view, "#quest-narration-#{c.character.id}")
        {:ok, before} = Ticks.fetch_draft(c.campaign.id, tick.id)

        for malformed <- [%{}, [], nil] do
          render_hook(view, "reroll", %{"die" => malformed})
          assert has_element?(view, "#flash-error")
          assert {:ok, ^before} = Ticks.fetch_draft(c.campaign.id, tick.id)
        end

        for malformed <- [%{}, %{"input" => nil}, %{"input" => []}, [], nil] do
          render_hook(view, "quest_edit", %{"quest" => malformed})
          assert has_element?(view, "#flash-error")
          assert {:ok, ^before} = Ticks.fetch_draft(c.campaign.id, tick.id)
        end

        view
        |> form("#quest-narration-#{c.character.id}",
          quest: %{value: "Invalid" <> <<0>> <> " narration", reason: "Storage validation"}
        )
        |> render_submit()

        assert has_element?(view, "#flash-error")
        assert {:ok, ^before} = Ticks.fetch_draft(c.campaign.id, tick.id)

        render_hook(view, "quest_edit", %{
          "quest" => %{
            "type" => "outcome",
            "input_revision" => snapshot.revision,
            "input" => Jason.encode!(hd(snapshot.data["quest_inputs"]["submissions"])),
            "draft_id" => before.id,
            "value" => "success",
            "reason" => "Forged fixed override"
          }
        })

        assert has_element?(view, "#flash-error")
        assert {:ok, ^before} = Ticks.fetch_draft(c.campaign.id, tick.id)
      end

      view |> form("#publish-form", publish: %{confirm: "true"}) |> render_submit()

      assert_redirect(view, ~p"/dashboard")
      assert {:ok, %{status: :published}} = Ticks.fetch_tick(c.campaign.id, tick.id)
      assert {:ok, _} = Ticks.fetch_publication(c.campaign.id, tick.id)
    end
  end
end
