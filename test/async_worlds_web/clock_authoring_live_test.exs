defmodule AsyncWorldsWeb.ClockAuthoringLiveTest do
  use AsyncWorldsWeb.ConnCase
  use Oban.Testing, repo: AsyncWorlds.Repo
  import Phoenix.LiveViewTest
  import Ecto.Query
  alias AsyncWorlds.{Campaigns, Characters, Clocks, Quests, Repo, Ticks, WebAuth}
  alias AsyncWorlds.Discord.{Dispatcher, FakeAdapter}

  setup %{conn: conn} do
    {:ok, campaign} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "123",
        dm_user_id: "456",
        public_channel_id: "789"
      })

    clocks =
      for {visibility, name} <- [
            {:public, "Town bell"},
            {:known, "Known ritual"},
            {:hidden, "Hidden conspiracy"}
          ] do
        {:ok, clock} =
          Clocks.create_clock(
            campaign.id,
            %{name: name, segments: 4, visibility: visibility},
            "dm"
          )

        clock
      end

    {:ok, work} = Quests.create_working_copy(campaign, "456")
    conn = log_in_dm(conn, campaign)
    {:ok, view, _} = live(conn, ~p"/quests/library?draft_id=#{work.id}")
    view |> element("#add-choice-0") |> render_click()

    fill(view, %{
      name: "Clock rehearsal",
      node_0_text: "The crossing",
      node_0_choice_0_label: "Cross",
      node_0_choice_0_text: "Crossed"
    })

    %{conn: conn, campaign: campaign, clocks: clocks, work: work, view: view}
  end

  defp fill(view, params),
    do: view |> form("#quest-editor-form", quest: params) |> render_change()

  defp save(view), do: view |> form("#quest-editor-form") |> render_submit()

  defp release(view),
    do: view |> form("#quest-editor-form") |> render_submit(%{"operation" => "release"})

  defp buttons(payload), do: Enum.flat_map(payload.components, & &1.components)

  defp interaction(command, id),
    do: %{
      type: 2,
      id: id,
      application_id: 111,
      guild_id: 123,
      member: %{user_id: 991},
      token: "offline-only",
      data: %{name: command}
    }

  test "forms through publication: intermediate clamps, later triggers, final eligibility and exact privacy",
       c do
    [public, known, hidden] = c.clocks
    v = c.view
    v |> element("#condition-0-0-add-clock") |> render_click()

    fill(v, %{
      node_0_choice_0_condition_0_clock_id: to_string(hidden.id),
      node_0_choice_0_condition_0_operator: "lte",
      node_0_choice_0_condition_0_value: "0"
    })

    assert has_element?(
             v,
             "#choice-0-0-condition-0-clock option",
             "Town bell · 4 segments · public: identity and fill visible"
           )

    assert has_element?(
             v,
             "#choice-0-0-condition-0-clock option",
             "Known ritual · 4 segments · known: fill private"
           )

    assert has_element?(v, "#choice-0-0-condition-0-summary", "hidden: identity and fill private")
    assert has_element?(v, "#choice-0-0-condition-0-summary", "fill at most 0")
    v |> element("#condition-0-0-add-clock") |> render_click()
    v |> element("#condition-0-0-1-up") |> render_click()
    v |> element("#condition-0-0-0-down") |> render_click()
    v |> element("#condition-0-0-1-remove") |> render_click()
    refute has_element?(v, "#choice-0-0-condition-1")
    v |> element("#add-choice-0") |> render_click()
    v |> element("#condition-0-1-add-clock") |> render_click()

    fill(v, %{
      node_0_choice_1_label: "Secret route",
      node_0_choice_1_text: "Secret route taken",
      node_0_choice_1_eligibility: "hidden",
      node_0_choice_1_condition_0_clock_id: to_string(hidden.id),
      node_0_choice_1_condition_0_value: "4"
    })

    # Mixed effects retain their order. +9 clamps to 4; -3 then yields 1,
    # unlike summing the deltas. Completion is latched for the later phase.
    for type <- ~w(clock_delta set_flag clock_delta clock_delta clock_delta),
        do: v |> element("#choice-0-0-effect-add-#{type}") |> render_click()

    fill(v, %{
      node_0_choice_0_effect_0_clock_id: to_string(hidden.id),
      node_0_choice_0_effect_0_delta: "9",
      node_0_choice_0_effect_1_key: "trigger_ready",
      node_0_choice_0_effect_1_value: "false",
      node_0_choice_0_effect_2_clock_id: to_string(hidden.id),
      node_0_choice_0_effect_2_delta: "-3",
      node_0_choice_0_effect_3_clock_id: to_string(known.id),
      node_0_choice_0_effect_3_delta: "-9",
      node_0_choice_0_effect_4_clock_id: to_string(public.id),
      node_0_choice_0_effect_4_delta: "2"
    })

    v |> element("#choice-0-0-effect-2-up") |> render_click()
    v |> element("#choice-0-0-effect-1-down") |> render_click()
    v |> element("#add-quest-node") |> render_click()
    v |> element("#add-choice-1") |> render_click()
    v |> element("#add-choice-1") |> render_click()
    for j <- 0..1, do: v |> element("#condition-1-#{j}-add-clock") |> render_click()
    v |> element("#condition-1-0-add") |> render_click()

    fill(v, %{
      node_1_text: "The far bank",
      node_1_choice_0_label: "Continue",
      node_1_choice_0_text: "Continued",
      node_1_choice_0_condition_0_clock_id: to_string(hidden.id),
      node_1_choice_0_condition_0_operator: "gte",
      node_1_choice_0_condition_0_value: "1",
      node_1_choice_0_condition_1_key: "trigger_ready",
      node_1_choice_1_label: "Blocked",
      node_1_choice_1_text: "Blocked",
      node_1_choice_1_condition_0_clock_id: to_string(hidden.id),
      node_1_choice_1_condition_0_operator: "gte",
      node_1_choice_1_condition_0_value: "4"
    })

    save(v)
    {:ok, saved} = Quests.get_working_copy(c.campaign, "456", c.work.id)
    [_, next] = saved.definition["nodes"]

    fill(v, %{
      node_0_choice_0_destination: next["id"],
      node_0_choice_1_destination: next["id"],
      node_1_choice_0_destination: next["id"],
      node_1_choice_1_destination: next["id"]
    })

    release(v)
    assert has_element?(v, "#flash-info", "Released revision 1")
    {:ok, reopened, _} = live(c.conn, ~p"/quests/library?draft_id=#{c.work.id}")
    assert has_element?(reopened, "#choice-0-0-condition-0-operator option[value=lte][selected]")
    assert has_element?(reopened, "#choice-0-0-effect-2-delta[value='-3']")
    {:ok, %{revisions: [revision]}} = Quests.library(c.campaign, "456")

    {:ok, character} =
      Characters.create_character(c.campaign, "456", %{name: "Player", discord_user_id: "991"})

    {:ok, assignment, _} = live(c.conn, ~p"/quests?character_id=#{character.id}")

    assignment
    |> form("#quest-assignment-form",
      intervention: %{revision_id: to_string(revision.id), reason: "Clock rehearsal"}
    )
    |> render_submit()

    assert has_element?(assignment, "#quest-current-position")
    assert Repo.get_by!(Quests.Progression, character_id: character.id).revision_id == revision.id

    {:ok, _} =
      Quests.configure_clock_triggers(c.campaign, "456", hidden.id, [
        %{
          "type" => "set_flag",
          "character_id" => character.id,
          "key" => "trigger_ready",
          "flag" => %{"type" => "boolean", "value" => true, "player_visible" => false}
        }
      ])

    start_supervised!({FakeAdapter, owner: self()})
    opts = [adapter: FakeAdapter, guild_id: "123", application_id: "111"]
    {:ok, tick} = Ticks.open_tick(c.campaign.id)
    {:ok, payload} = Dispatcher.handle(interaction("quest", 901), opts)
    refute payload.content =~ hidden.name
    refute payload.content =~ "trigger_ready"
    refute payload.content =~ "Secret route"
    refute Enum.any?(buttons(payload), &(&1.label =~ "Secret route"))
    button = Enum.find(buttons(payload), &(&1.label =~ "Cross"))
    assert !button.disabled

    assert {:ok, _} =
             Dispatcher.handle(
               %{
                 interaction("quest", 902)
                 | type: 3,
                   data: %{custom_id: button.custom_id, component_type: 2}
               },
               opts
             )

    {:ok, %{snapshot: snapshot}} = Ticks.close_tick(c.campaign.id, tick.id)
    original = Repo.get!(Quests.Revision, revision.id)
    fill(reopened, %{node_0_choice_0_effect_0_delta: "0"})
    release(reopened)
    assert has_element?(reopened, "#flash-info", "Released revision 2")
    assert Repo.get!(Quests.Revision, revision.id) == original
    assert Repo.get!(Ticks.Snapshot, snapshot.id) == snapshot
    assert Repo.get_by!(Quests.Progression, character_id: character.id).revision_id == revision.id

    assert :ok =
             perform_job(AsyncWorlds.Workers.ResolveTick, %{
               campaign_id: c.campaign.id,
               tick_id: tick.id,
               input_revision: snapshot.revision
             })

    {:ok, draft} = Ticks.fetch_draft(c.campaign.id, tick.id)
    resolved = Map.new(draft.payload["clocks"], &{&1["id"], &1})
    assert resolved[hidden.id]["filled"] == 1
    assert resolved[known.id]["filled"] == 0
    assert resolved[public.id]["filled"] == 2

    changes =
      Enum.filter(
        draft.payload["log"],
        &(&1["kind"] == "clock_change" and &1["clock_id"] == hidden.id)
      )

    assert Enum.map(
             Enum.filter(changes, &(&1["phase"] == "quest_choices")),
             & &1["after"]["filled"]
           ) == [4, 1]

    assert hd(Clocks.list_clocks(c.campaign.id)).filled == 0
    {:ok, review, _} = live(c.conn, ~p"/ticks/#{tick.id}/review")
    assert has_element?(review, "#quest-next-#{character.id}", "Continue")
    assert has_element?(review, "#quest-next-#{character.id}", "Not available right now")
    assert has_element?(review, "#resolution-log", "quest:tick:")
    assert has_element?(review, "#resolution-log", "clock_triggers")
    refute has_element?(review, "#public-preview", hidden.name)
    refute has_element?(review, "#public-preview", known.name <> ":")
    refute has_element?(review, "#public-preview", "trigger_ready")
    assert has_element?(review, "#private-preview", hidden.name <> ": 1/4")
    assert has_element?(review, "#private-preview", known.name <> ": 0/4")
    {:ok, preview} = Ticks.preview_draft(c.campaign.id, tick.id, draft.id)

    for message <- preview["players"] do
      refute message["content"] =~ hidden.name
      refute message["content"] =~ known.name
      refute message["content"] =~ "trigger_ready"
    end

    review |> form("#publish-form", publish: %{confirm: "true"}) |> render_submit()
    assert_redirect(review, ~p"/dashboard")
    {:ok, publication} = Ticks.fetch_publication(c.campaign.id, tick.id)
    assert publication.outputs == preview
    messages = for {_, values} <- preview, message <- values, do: message

    deliveries =
      Enum.reject(
        AsyncWorlds.Deliveries.list_deliveries(c.campaign.id),
        &String.ends_with?(&1.key, ":opened")
      )

    assert Enum.sort(
             Enum.map(deliveries, &{Atom.to_string(&1.kind), &1.recipient_id, &1.content})
           ) ==
             Enum.sort(Enum.map(messages, &{&1["kind"], &1["recipient_id"], &1["content"]}))

    assert Repo.get!(Clocks.Clock, hidden.id).filled == 1
    assert Repo.get!(Characters.Character, character.id).flags["trigger_ready"]["value"] == true
    assert {:ok, _} = Ticks.open_tick(c.campaign.id)
    {:ok, fresh} = Dispatcher.handle(interaction("quest", 903), opts)
    assert !Enum.find(buttons(fresh), &(&1.label =~ "Continue")).disabled
    assert Enum.find(buttons(fresh), &(&1.label =~ "Blocked")).disabled
    refute fresh.content =~ hidden.name
    {:ok, clocks_text} = Dispatcher.handle(interaction("clocks", 904), opts)
    assert clocks_text =~ public.name
    assert clocks_text =~ known.name
    refute clocks_text =~ hidden.name
    refute clocks_text =~ "Known ritual: 0"
    assert is_map(preview)

    assert {:error, :stale_component} =
             Dispatcher.handle(
               %{
                 interaction("quest", 905)
                 | type: 3,
                   data: %{custom_id: button.custom_id, component_type: 2}
               },
               opts
             )
  end

  test "rolled outcomes and critical clock bonuses reuse ordered controls and resolve controlled dice",
       c do
    v = c.view
    hidden = List.last(c.clocks)
    v |> element("#choice-0-0-convert") |> render_click()
    v |> element("#confirm-choice-conversion") |> render_click()
    v |> element("#condition-0-0-add-clock") |> render_click()

    fill(v, %{
      node_0_choice_0_dice: "2",
      node_0_choice_0_condition_0_clock_id: to_string(hidden.id),
      node_0_choice_0_condition_0_operator: "lte",
      node_0_choice_0_condition_0_value: "4"
    })

    for kind <- ~w(success partial failure) do
      v |> element("#choice-0-0_#{kind}-effect-add-clock_delta") |> render_click()

      fill(v, %{
        "node_0_choice_0_#{kind}_text" => "#{kind} narration",
        "node_0_choice_0_#{kind}_effect_0_clock_id" => to_string(hidden.id),
        "node_0_choice_0_#{kind}_effect_0_delta" => "2"
      })
    end

    for type <- ~w(clock_delta clear_flag clock_delta clock_delta),
        do: v |> element("#critical-0-0-add-#{type}") |> render_click()

    fill(v, %{
      node_0_choice_0_critical_0_clock_id: to_string(hidden.id),
      node_0_choice_0_critical_0_delta: "9",
      node_0_choice_0_critical_1_key: "secret",
      node_0_choice_0_critical_2_clock_id: to_string(hidden.id),
      node_0_choice_0_critical_2_delta: "-3"
    })

    v |> element("#critical-0-0-3-remove") |> render_click()
    v |> element("#critical-0-0-2-up") |> render_click()
    v |> element("#critical-0-0-1-down") |> render_click()
    save(v)
    {:ok, work} = Quests.get_working_copy(c.campaign, "456", c.work.id)
    id = hd(work.definition["nodes"])["id"]

    fill(v, %{
      node_0_choice_0_success_destination: id,
      node_0_choice_0_partial_destination: id,
      node_0_choice_0_failure_destination: id
    })

    release(v)
    assert has_element?(v, "#flash-info", "Released revision 1")
    {:ok, reopened, _} = live(c.conn, ~p"/quests/library?draft_id=#{c.work.id}")
    assert has_element?(reopened, "#choice-0-0-critical-2-delta[value='-3']")
    assert has_element?(reopened, "#choice-0-0_failure-effect-0-summary", hidden.name)
    {:ok, %{revisions: [r]}} = Quests.library(c.campaign, "456")
    {:ok, revision} = Quests.get_revision(c.campaign, "456", r.id)
    choice = hd(hd(revision.definition["nodes"])["choices"])

    assert Enum.map(choice["critical_effects"], & &1["type"]) ==
             ~w(clock_delta clear_flag clock_delta)

    {:ok, character} =
      Characters.create_character(c.campaign, "456", %{name: "Player", discord_user_id: "991"})

    {:ok, assignment, _} = live(c.conn, ~p"/quests?character_id=#{character.id}")

    assignment
    |> form("#quest-assignment-form",
      intervention: %{revision_id: to_string(r.id), reason: "Rolled clock rehearsal"}
    )
    |> render_submit()

    assert has_element?(assignment, "#quest-current-position")
    assert Repo.get_by!(Quests.Progression, character_id: character.id).revision_id == r.id
    start_supervised!({FakeAdapter, owner: self()})
    opts = [adapter: FakeAdapter, guild_id: "123", application_id: "111"]
    {:ok, tick} = Ticks.open_tick(c.campaign.id)
    {:ok, payload} = Dispatcher.handle(interaction("quest", 930), opts)
    button = hd(buttons(payload))

    {:ok, _} =
      Dispatcher.handle(
        %{
          interaction("quest", 931)
          | type: 3,
            data: %{custom_id: button.custom_id, component_type: 2}
        },
        opts
      )

    {:ok, %{snapshot: snapshot}} = Ticks.close_tick(c.campaign.id, tick.id)

    {:ok, rolls} =
      Ticks.record_quest_rolls(c.campaign.id, tick.id, snapshot.revision, fn -> 6 end)

    assert Enum.map(rolls, & &1["value"]) == [6, 6]

    assert :ok =
             perform_job(AsyncWorlds.Workers.ResolveTick, %{
               campaign_id: c.campaign.id,
               tick_id: tick.id,
               input_revision: snapshot.revision
             })

    {:ok, draft} = Ticks.fetch_draft(c.campaign.id, tick.id)
    assert hd(draft.payload["private_results"])["critical"]

    changes =
      Enum.filter(
        draft.payload["effects"],
        &(&1["clock_id"] == hidden.id and &1["phase"] == "quest_choices")
      )

    assert Enum.map(changes, & &1["after"]["filled"]) == [2, 4, 1]
    {:ok, review, _} = live(c.conn, ~p"/ticks/#{tick.id}/review")
    refute has_element?(review, "#public-preview", hidden.name)
    review |> form("#publish-form", publish: %{confirm: "true"}) |> render_submit()
    assert_redirect(review, ~p"/dashboard")
    assert Repo.get!(Clocks.Clock, hidden.id).filled == 1
    assert {:ok, _} = Ticks.open_tick(c.campaign.id)
    {:ok, fresh} = Dispatcher.handle(interaction("quest", 932), opts)
    refute fresh.content =~ hidden.name
    assert !hd(buttons(fresh)).disabled
  end

  test "forged clock values block release with field errors and never create a revision", c do
    v = c.view
    [clock | _] = c.clocks

    {:ok, foreign} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "124",
        dm_user_id: "457",
        public_channel_id: "790"
      })

    {:ok, foreign_clock} =
      Clocks.create_clock(foreign.id, %{name: "Foreign secret", segments: 4}, "dm")

    v |> element("#condition-0-0-add-clock") |> render_click()
    v |> element("#choice-0-0-effect-add-clock_delta") |> render_click()
    refute has_element?(v, "#choice-0-0-condition-0-clock option", foreign_clock.name)
    save(v)
    {:ok, saved} = Quests.get_working_copy(c.campaign, "456", c.work.id)
    node = hd(saved.definition["nodes"])

    fill(v, %{
      node_0_choice_0_destination: node["id"],
      node_0_choice_0_condition_0_clock_id: to_string(clock.id),
      node_0_choice_0_effect_0_clock_id: to_string(clock.id)
    })

    for {key, value, target} <- [
          {"clock_id", "999999", "clock"},
          {"clock_id", to_string(foreign_clock.id), "clock"},
          {"operator", "eq", "operator"},
          {"value", "-1", "value"},
          {"value", "5", "value"},
          {"value", "1.5", "value"}
        ] do
      render_submit(v, "save", %{
        "operation" => "release",
        "quest" => %{"node_0_choice_0_condition_0_#{key}" => value}
      })

      assert has_element?(v, "#draft-errors a[href='#choice-0-0-condition-0-#{target}']")

      fill(v, %{
        node_0_choice_0_condition_0_clock_id: to_string(clock.id),
        node_0_choice_0_condition_0_operator: "gte",
        node_0_choice_0_condition_0_value: "0"
      })
    end

    render_submit(v, "save", %{
      "operation" => "release",
      "quest" => %{"node_0_choice_0_effect_0_clock_id" => to_string(foreign_clock.id)}
    })

    assert has_element?(v, "#draft-errors a[href='#choice-0-0-effect-0-clock']")
    fill(v, %{node_0_choice_0_effect_0_clock_id: to_string(clock.id)})

    for delta <- ["1.5", "oops"] do
      render_change(v, "change", %{
        "quest" => %{
          "node_0_choice_0_effect_0_delta" => delta,
          "actor_id" => "999",
          "campaign_id" => "999"
        }
      })

      release(v)
      assert has_element?(v, "#draft-errors a[href='#choice-0-0-effect-0-delta']")
    end

    assert {:ok, %{revisions: []}} = Quests.library(c.campaign, "456")
    assert Repo.get!(Quests.WorkingCopy, saved.id) == saved
  end

  test "clock local typing never locks campaign; stale and expired tabs fail closed", c do
    save(c.view)
    {:ok, stale, _} = live(c.conn, ~p"/quests/library?draft_id=#{c.work.id}")
    owner = self()
    handler = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler,
      [:async_worlds, :repo, :query],
      fn _, _, metadata, _ ->
        if self() == stale.pid and String.contains?(metadata.query, "FOR UPDATE"),
          do: send(owner, :write_lock)
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    stale |> element("#condition-0-0-add-clock") |> render_click()

    fill(stale, %{
      node_0_choice_0_condition_0_clock_id: to_string(hd(c.clocks).id),
      node_0_choice_0_condition_0_value: "4"
    })

    refute_receive :write_lock, 0
    fill(c.view, %{name: "Other tab"})
    save(c.view)
    save(stale)
    assert has_element?(stale, "#draft-conflict")
    stale |> element("#reload-draft") |> render_click()
    stale |> element("#recover-draft") |> render_click()
    assert has_element?(stale, "#choice-0-0-condition-0-value[value='4']")
    token = get_session(get(c.conn, ~p"/dashboard"), :web_session_token)
    {:ok, scope} = WebAuth.authorize_session(token)

    Repo.update_all(from(s in WebAuth.Session, where: s.id == ^scope.session_id),
      set: [expires_at: DateTime.add(DateTime.utc_now(), -60, :second)]
    )

    render_click(stale, "choice-list", %{
      "node" => "forged",
      "choice" => "forged",
      "list" => "conditions",
      "action" => "clock_threshold"
    })

    assert_redirect(stale, "/login")
  end

  test "revoked sessions cannot release locally authored clock effects", c do
    v = c.view
    v |> element("#choice-0-0-effect-add-clock_delta") |> render_click()

    fill(v, %{
      node_0_choice_0_effect_0_clock_id: to_string(hd(c.clocks).id),
      node_0_choice_0_effect_0_delta: "-2"
    })

    token = get_session(get(c.conn, ~p"/dashboard"), :web_session_token)
    :ok = WebAuth.revoke_session(token)
    assert_redirect(v, "/login")
    assert Repo.get!(Quests.WorkingCopy, c.work.id) == c.work
    assert Repo.aggregate(Quests.Revision, :count) == 0
  end
end
