defmodule AsyncWorldsWeb.RolledAuthoringLiveTest do
  use AsyncWorldsWeb.ConnCase
  use Oban.Testing, repo: AsyncWorlds.Repo
  import Phoenix.LiveViewTest
  alias AsyncWorlds.{Campaigns, Characters, Clocks, Quests, Repo, Ticks}
  alias AsyncWorlds.Discord.{Dispatcher, FakeAdapter}

  setup %{conn: conn} do
    {:ok, campaign} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "123",
        dm_user_id: "456",
        public_channel_id: "789"
      })

    {:ok, clock} = Clocks.create_clock(campaign.id, %{name: "Bonus", segments: 4}, "dm")
    {:ok, work} = Quests.create_working_copy(campaign, "456")
    {:ok, view, _} = live(log_in_dm(conn, campaign), ~p"/quests/library?draft_id=#{work.id}")
    %{conn: log_in_dm(conn, campaign), campaign: campaign, clock: clock, work: work, view: view}
  end

  defp fill(view, params),
    do: view |> form("#quest-editor-form", quest: params) |> render_change()

  defp save(view), do: view |> form("#quest-editor-form") |> render_submit()

  defp release(view),
    do: view |> form("#quest-editor-form") |> render_submit(%{"operation" => "release"})

  defp convert(view) do
    view |> element("#choice-0-0-convert") |> render_click()
    assert has_element?(view, "#choice-conversion-warning")
    view |> element("#confirm-choice-conversion") |> render_click()
  end

  test "confirmed conversion, typed authoring, save/reopen, controlled outcomes and selective review publication",
       c do
    v = c.view
    v |> element("#add-choice-0") |> render_click()

    fill(v, %{
      name: "Dice rehearsal",
      node_0_text: "Attempt the crossing",
      node_0_choice_0_label: "Cross",
      node_0_choice_0_text: "Safely across"
    })

    v |> element("#choice-0-0-convert") |> render_click()
    v |> element("#cancel-choice-conversion") |> render_click()
    assert has_element?(v, "#choice-0-0-text", "Safely across")
    refute has_element?(v, "#choice-0-0-dice")
    convert(v)
    assert has_element?(v, "#choice-0-0_success-text", "Safely across")
    v |> element("#add-quest-node") |> render_click()
    save(v)
    {:ok, saved} = Quests.get_working_copy(c.campaign, "456", c.work.id)
    [entry, ending] = saved.definition["nodes"]

    fill(v, %{
      node_1_text: "Across",
      node_1_ending: "true",
      node_0_choice_0_dice: "3",
      node_0_choice_0_success_destination: ending["id"],
      node_0_choice_0_partial_text: "A narrow escape",
      node_0_choice_0_partial_destination: entry["id"],
      node_0_choice_0_failure_text: "Try again",
      node_0_choice_0_failure_destination: entry["id"]
    })

    for type <- ~w(set_flag clear_flag set_flag clock_delta),
        do: v |> element("#critical-0-0-add-#{type}") |> render_click()

    fill(v, %{
      node_0_choice_0_critical_0_flag_type: "string",
      node_0_choice_0_critical_2_flag_type: "integer"
    })

    fill(v, %{
      node_0_choice_0_critical_0_key: "reward",
      node_0_choice_0_critical_0_flag_type: "string",
      node_0_choice_0_critical_0_value: "first",
      node_0_choice_0_critical_1_key: "reward",
      node_0_choice_0_critical_2_key: "reward",
      node_0_choice_0_critical_2_flag_type: "integer",
      node_0_choice_0_critical_2_value: "7",
      node_0_choice_0_critical_3_clock_id: to_string(c.clock.id),
      node_0_choice_0_critical_3_delta: "1"
    })

    assert has_element?(v, "textarea#choice-0-0-critical-0-value", "first")
    v |> element("#critical-0-0-3-up") |> render_click()
    v |> element("#critical-0-0-2-down") |> render_click()
    save(v)
    {:ok, reopened, _} = live(c.conn, ~p"/quests/library?draft_id=#{c.work.id}")
    assert has_element?(reopened, "#choice-0-0-dice[value='3']")
    assert has_element?(reopened, "#choice-0-0-critical-2-value[value='7']")
    release(reopened)
    assert has_element?(reopened, "#flash-info", "Released revision 1")
    {:ok, %{revisions: [revision]}} = Quests.library(c.campaign, "456")
    {:ok, revision} = Quests.get_revision(c.campaign, "456", revision.id)
    authored = hd(hd(revision.definition["nodes"])["choices"])
    assert authored["dice"] === 3

    assert Enum.map(authored["critical_effects"], & &1["type"]) ==
             ~w(set_flag clear_flag set_flag clock_delta)

    characters =
      for user <- ~w(991 992 993 994) do
        {:ok, character} =
          Characters.create_character(c.campaign, "456", %{name: user, discord_user_id: user})

        {:ok, _} = Quests.assign(c.campaign, "456", character.id, revision.id)
        character
      end

    start_supervised!({FakeAdapter, owner: self()})
    opts = [adapter: FakeAdapter, guild_id: "123", application_id: "111"]
    {:ok, tick} = Ticks.open_tick(c.campaign.id)

    for character <- characters do
      interaction = %{
        type: 2,
        id: character.id + 900,
        application_id: 111,
        guild_id: 123,
        member: %{user_id: String.to_integer(character.discord_user_id)},
        token: "offline-only",
        data: %{name: "quest"}
      }

      {:ok, payload} = Dispatcher.handle(interaction, opts)

      button =
        payload.components |> Enum.flat_map(& &1.components) |> Enum.find(&(&1.label =~ "Cross"))

      assert {:ok, _} =
               Dispatcher.handle(
                 %{
                   interaction
                   | type: 3,
                     id: character.id + 1900,
                     data: %{custom_id: button.custom_id, component_type: 2}
                 },
                 opts
               )
    end

    {:ok, %{snapshot: snapshot}} = Ticks.close_tick(c.campaign.id, tick.id)
    roller = start_supervised!({Agent, fn -> [1, 2, 3, 4, 1, 2, 6, 1, 2, 6, 6, 1] end})

    {:ok, rolls} =
      Ticks.record_quest_rolls(c.campaign.id, tick.id, snapshot.revision, fn ->
        Agent.get_and_update(roller, fn [value | rest] -> {value, rest} end)
      end)

    assert :ok =
             perform_job(AsyncWorlds.Workers.ResolveTick, %{
               campaign_id: c.campaign.id,
               tick_id: tick.id,
               input_revision: snapshot.revision
             })

    {:ok, draft} = Ticks.fetch_draft(c.campaign.id, tick.id)

    assert Enum.map(draft.payload["private_results"], & &1["outcome"]) ==
             ~w(failure partial success success)

    assert Enum.map(draft.payload["private_results"], & &1["critical"]) == [
             false,
             false,
             false,
             true
           ]

    assert hd(Clocks.list_clocks(c.campaign.id)).filled == 0

    for character <- characters,
        do: assert(Repo.get!(Characters.Character, character.id).flags == %{})

    {:ok, review, _} = live(c.conn, ~p"/ticks/#{tick.id}/review")
    [first | _] = characters

    review
    |> form("#quest-die-#{first.id}-0", die: %{reason: "Selected die only"})
    |> render_submit()

    {:ok, edited} = Ticks.fetch_draft(c.campaign.id, tick.id)
    assert Enum.drop(edited.payload["rolls"], 1) == Enum.drop(rolls, 1)
    {:ok, [audit]} = Ticks.list_review_edits(c.campaign.id, tick.id)
    assert audit.operation["type"] == "reroll"
    assert audit.operation["old_value"] == 1
    critical = List.last(characters)

    review
    |> form("#quest-outcome-#{critical.id}",
      quest: %{value: "partial", reason: "Inspect override"}
    )
    |> render_submit()

    {:ok, overridden} = Ticks.fetch_draft(c.campaign.id, tick.id)
    refute List.last(overridden.payload["private_results"])["critical"]

    review
    |> form("#quest-outcome-#{critical.id}",
      quest: %{value: "", reason: "Restore controlled dice"}
    )
    |> render_submit()

    review |> form("#publish-form", publish: %{confirm: "true"}) |> render_submit()
    assert_redirect(review, ~p"/dashboard")
    assert Repo.get!(Characters.Character, critical.id).flags["reward"]["value"] === 7
    assert hd(Clocks.list_clocks(c.campaign.id)).filled == 1
    assert Repo.get_by!(Quests.Progression, character_id: critical.id).status == :completed

    for character <- Enum.take(characters, 3),
        do: assert(Repo.get!(Characters.Character, character.id).flags == %{})

    convert(reopened)
    assert has_element?(reopened, "#choice-0-0-text", "Safely across")
    refute has_element?(reopened, "#choice-0-0-critical")
    save(reopened)
    {:ok, fixed, _} = live(c.conn, ~p"/quests/library?draft_id=#{c.work.id}")
    assert has_element?(fixed, "#choice-0-0-text", "Safely across")
    release(fixed)
    assert has_element?(fixed, "#flash-info", "Released revision 2")
    assert {:ok, ^revision} = Quests.get_revision(c.campaign, "456", revision.id)
  end

  test "invalid pools, missing outcome text, destinations and typed bonuses block release atomically",
       c do
    c.view |> element("#add-choice-0") |> render_click()
    convert(c.view)

    for invalid <- ["0", "4", "1.5", "bogus"] do
      render_change(c.view, "change", %{"quest" => %{"node_0_choice_0_dice" => invalid}})
      release(c.view)

      assert has_element?(
               c.view,
               "#draft-errors a[href='#choice-0-0-dice']",
               "integer from 1 to 3"
             )

      assert has_element?(c.view, "#draft-errors a[href='#choice-0-0_success-text']")
      assert has_element?(c.view, "#draft-errors a[href='#choice-0-0_partial-destination']")
      assert {:ok, %{revisions: []}} = Quests.library(c.campaign, "456")
      assert {:ok, unchanged} = Quests.get_working_copy(c.campaign, "456", c.work.id)
      assert unchanged == c.work
    end

    c.view |> element("#critical-0-0-add-clock_delta") |> render_click()
    release(c.view)

    assert has_element?(
             c.view,
             "#draft-errors a[href='#choice-0-0-critical-0-clock']",
             "this campaign"
           )

    save(c.view)
    assert has_element?(c.view, "#flash-info", "saved")
  end

  test "stale rolled edits recover by draft identity and forged effect targets cannot mutate another choice",
       c do
    c.view |> element("#add-choice-0") |> render_click()
    convert(c.view)
    save(c.view)
    {:ok, stale, _} = live(c.conn, ~p"/quests/library?draft_id=#{c.work.id}")
    fill(stale, %{node_0_choice_0_dice: "2", node_0_choice_0_partial_text: "Unsaved partial"})
    stale |> element("#critical-0-0-add-set_flag") |> render_click()
    fill(stale, %{node_0_choice_0_critical_0_key: "saved_work"})
    fill(c.view, %{name: "Other tab"})
    save(c.view)
    save(stale)
    assert has_element?(stale, "#draft-conflict")
    stale |> element("#reload-draft") |> render_click()
    stale |> element("#recover-draft") |> render_click()
    assert has_element?(stale, "#choice-0-0-dice[value='2']")
    assert has_element?(stale, "#choice-0-0_partial-text", "Unsaved partial")
    assert has_element?(stale, "#choice-0-0-critical-0-key[value='saved_work']")
    {:ok, %{drafts: drafts}} = Quests.library(c.campaign, "456")
    recovered = Enum.find(drafts, &(&1.id != c.work.id))
    assert recovered
    assert Enum.find(drafts, &(&1.id == c.work.id)).name == "Other tab"
    owner = self()
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:async_worlds, :repo, :query],
        fn _, _, metadata, _ ->
          if self() == stale.pid and
               (String.contains?(metadata.query, "FOR UPDATE") or
                  String.contains?(metadata.query, "quest_revisions")),
             do: send(owner, {:locking_query, metadata.query})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    for node <- ["foreign", [], nil], choice <- ["foreign", [], nil] do
      render_click(stale, "critical-effect", %{
        "node" => node,
        "choice" => choice,
        "action" => "remove",
        "index" => "0",
        "campaign_id" => "999",
        "actor_id" => "999"
      })

      render_click(stale, "convert-choice", %{
        "node" => node,
        "choice" => choice,
        "mode" => "fixed"
      })

      render_click(stale, "confirm-conversion", %{})
    end

    refute_receive {:locking_query, _}, 0
    assert has_element?(stale, "#choice-0-0-critical-0-key[value='saved_work']")
    save(stale)
    {:ok, saved} = Quests.get_working_copy(c.campaign, "456", recovered.id)
    assert saved.definition == recovered.definition
  end
end
