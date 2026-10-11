defmodule AsyncWorldsWeb.QuestLiveTest do
  use AsyncWorldsWeb.ConnCase
  import Phoenix.LiveViewTest
  import AsyncWorlds.QuestFixtures
  alias AsyncWorlds.{Campaigns, Characters, Quests, Repo, Ticks, WebAuth}
  alias AsyncWorlds.Quests.{Progression, Submissions}

  setup %{conn: conn} do
    {:ok, campaign} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "123",
        dm_user_id: "456",
        public_channel_id: "789"
      })

    {:ok, a} =
      Characters.create_character(campaign, "456", %{name: "Rook", discord_user_id: "991"})

    {:ok, b} =
      Characters.create_character(campaign, "456", %{name: "Finch", discord_user_id: "992"})

    {:ok, revision} =
      Quests.create_quest(
        campaign,
        "456",
        %{content_id: "quest", name: "The crossing"},
        definition()
      )

    %{conn: log_in_dm(conn, campaign), campaign: campaign, a: a, b: b, revision: revision}
  end

  defp choose(view, character),
    do: view |> element("#select-quest-character-#{character.id}") |> render_click()

  defp assign_quest(view, revision, reason \\ "Begin this story") do
    view
    |> form("#quest-assignment-form",
      intervention: %{revision_id: to_string(revision.id), reason: reason}
    )
    |> render_submit()
  end

  test "DM bootstraps independent quests, moves to endings, reassigns, swaps and ends without SQL",
       c do
    {:ok, view, _} = live(c.conn, ~p"/quests")
    assert has_element?(view, "#quest-select-prompt")
    assert has_element?(view, "#nav-quests[aria-current=page]")
    choose(view, c.a)
    assert has_element?(view, "#quest-selected-character", "Rook")
    assert has_element?(view, "#quest-audit-empty")
    assign_quest(view, c.revision)
    assert has_element?(view, "#quest-current-node", "hub")
    assert has_element?(view, "#quest-move-form")
    assert has_element?(view, "#quest-end-form")
    {:ok, state} = Quests.management_state(c.campaign, "456", c.a.id)
    first = state.selected.progression
    assert has_element?(view, "#interventions-#{hd(state.audits).id}", "Begin this story")
    choose(view, c.b)
    assign_quest(view, c.revision, "Same quest, another player")
    {:ok, state} = Quests.management_state(c.campaign, "456", c.b.id)
    second = state.selected.progression
    assert second.revision_id == first.revision_id
    refute second.id == first.id
    choose(view, c.a)

    view
    |> form("#quest-move-form", intervention: %{node_id: "end", reason: "Resolved at the table"})
    |> render_submit()

    refute has_element?(view, "#quest-current-position")
    refute has_element?(view, "#quest-end-form")
    assert Repo.get!(Progression, first.id).status == :completed
    assert Repo.get!(Progression, second.id) == second
    assign_quest(view, c.revision, "Start again")

    {:ok, revision2} =
      Quests.append_revision(c.campaign, "456", c.revision.quest_id, definition())

    view |> element("#refresh-quests") |> render_click()
    assign_quest(view, revision2, "Use new story revision")
    {:ok, state} = Quests.management_state(c.campaign, "456", c.a.id)
    swapped = state.selected.progression
    assert swapped.revision_id == revision2.id

    view
    |> form("#quest-end-form", intervention: %{reason: "Retire this story"})
    |> render_submit()

    assert Repo.get!(Progression, swapped.id).status == :ended
    refute has_element?(view, "#quest-current-position")
    assert has_element?(view, "#quest-assignment-form")
    assert has_element?(view, "#quest-interventions", "Retire this story")
  end

  test "interventions have explicit effects on submissions and current eligibility", c do
    {:ok, p} = Quests.assign(c.campaign, "456", c.a.id, c.revision.id)
    {:ok, _} = Quests.assign(c.campaign, "456", c.b.id, c.revision.id)
    {:ok, _} = Ticks.open_tick(c.campaign.id)
    {:ok, a_state} = Submissions.player_state("123", "991")
    {:ok, b_state} = Submissions.player_state("123", "992")
    {:ok, _} = Submissions.submit("123", "991", a_state.identity, "loop")
    {:ok, _} = Submissions.submit("123", "992", b_state.identity, "finish")
    {:ok, view, _} = live(c.conn, ~p"/quests?character_id=#{c.a.id}")

    assert has_element?(
             view,
             "#quest-intervention-policy",
             "clears this character's open submission"
           )

    view
    |> form("#quest-move-form", intervention: %{node_id: "hub", reason: "Already at this node"})
    |> render_submit()

    assert {:ok, %{choice_id: "loop"}} = Submissions.player_state("123", "991")

    view
    |> form("#quest-move-form", intervention: %{node_id: "end", reason: "End through play"})
    |> render_submit()

    assert Repo.get!(Progression, p.id).status == :completed
    assert {:error, :stale_identity} = Submissions.submit("123", "991", a_state.identity, "loop")
    assert {:ok, %{choice_id: "finish"}} = Submissions.player_state("123", "992")

    gated =
      choice("gated", "end")
      |> Map.put("conditions", [
        %{"type" => "character_flag", "key" => "ready", "flag_type" => "boolean", "value" => true}
      ])

    {:ok, revision} =
      Quests.append_revision(
        c.campaign,
        "456",
        c.revision.quest_id,
        replace_choice(definition(), gated)
      )

    view |> element("#refresh-quests") |> render_click()
    assign_quest(view, revision)
    {:ok, state} = Submissions.player_state("123", "991")
    assert [%{enabled: false}] = state.quest.choices

    assert {:error, :unavailable_choice} =
             Submissions.submit("123", "991", state.identity, "gated")

    {:ok, _} = Characters.set_flag(c.campaign, "456", c.a.id, "ready", flag())

    assert {:ok, %{quest: %{choices: [%{enabled: true}]}}} =
             Submissions.player_state("123", "991")

    {:ok, _} = Submissions.submit("123", "991", state.identity, "gated")
    # Swapping this pinned assignment clears the newly available choice too.
    assign_quest(view, c.revision, "Return to original")
    assert {:ok, %{choice_id: nil}} = Submissions.player_state("123", "991")
    {:ok, [swap | _]} = Quests.list_interventions(c.campaign, "456", c.a.id)
    assert swap.invalidated_submissions == 1
  end

  test "cross-campaign selections/revisions and foreign nodes are rejected with actionable errors",
       c do
    {:ok, other} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "124",
        dm_user_id: "457",
        public_channel_id: "790"
      })

    {:ok, foreign} =
      Characters.create_character(other, "457", %{name: "Foreign", discord_user_id: "993"})

    {:ok, foreign_revision} =
      Quests.create_quest(other, "457", %{content_id: "foreign", name: "Foreign"}, definition())

    {:ok, foreign_p} = Quests.assign(other, "457", foreign.id, foreign_revision.id)
    {:ok, view, _} = live(c.conn, ~p"/quests?character_id=#{foreign.id}")
    assert has_element?(view, "#flash-error", "not available in this campaign")
    refute has_element?(view, "#quest-selected-character")
    refute has_element?(view, "#select-quest-character-#{foreign.id}")
    choose(view, c.a)
    refute has_element?(view, "#quest-assignment-form option[value='#{foreign_revision.id}']")

    render_submit(view, "assign", %{
      "intervention" => %{
        "revision_id" => to_string(foreign_revision.id),
        "reason" => "Forged",
        "character_id" => foreign.id,
        "actor_id" => "457"
      }
    })

    assert has_element?(view, "#flash-error", "not available in this campaign")
    assert {:ok, []} = Quests.list_interventions(c.campaign, "456", c.a.id)
    assign_quest(view, c.revision)

    render_submit(view, "move", %{
      "intervention" => %{
        "node_id" => "foreign_node",
        "reason" => "Forged",
        "progression_id" => foreign_p.id
      }
    })

    assert has_element?(view, "#flash-error", "pinned quest revision")
    assert has_element?(view, "#quest-current-node", "hub")
    assert Repo.get!(Progression, foreign_p.id) == foreign_p
    render_click(view, "select", %{"id" => "bad"})
    assert has_element?(view, "#flash-error")
    refute has_element?(view, "#quest-selected-character")
  end

  test "new content does not change the pinned nodes until the DM explicitly replaces the quest",
       c do
    {:ok, _} = Quests.assign(c.campaign, "456", c.a.id, c.revision.id)
    [hub, ending] = definition()["nodes"]

    newer_node =
      hub |> Map.put("id", "new_node") |> Map.put("choices", [choice("new_choice", "end")])

    newer_definition = Map.put(definition(), "nodes", [hub, newer_node, ending])

    {:ok, newer} =
      Quests.append_revision(c.campaign, "456", c.revision.quest_id, newer_definition)

    {:ok, view, _} = live(c.conn, ~p"/quests?character_id=#{c.a.id}")
    refute has_element?(view, "#quest-move-form option[value=new_node]")
    assert has_element?(view, "#quest-assignment-form option[value='#{newer.id}']")

    render_submit(view, "move", %{
      "intervention" => %{"node_id" => "new_node", "reason" => "Wrong revision"}
    })

    assert has_element?(view, "#flash-error", "pinned quest revision")
    assign_quest(view, newer, "Opt into revision two")
    assert has_element?(view, "#quest-move-form option[value=new_node]")

    view
    |> form("#quest-move-form",
      intervention: %{node_id: "new_node", reason: "Use the new branch"}
    )
    |> render_submit()

    assert has_element?(view, "#quest-current-node", "new_node")
  end

  test "reasons are required server-side and missing or forged actions do not crash the view",
       c do
    {:ok, view, _} = live(c.conn, ~p"/quests?character_id=#{c.a.id}")

    for reason <- [
          nil,
          "",
          " ",
          "bad\u0000reason",
          String.duplicate("x", 2001),
          "a" <> String.duplicate("\u0301", 2001)
        ] do
      render_submit(view, "assign", %{
        "intervention" => %{"revision_id" => c.revision.id, "reason" => reason}
      })

      assert has_element?(view, "#flash-error", "audit reason is required")
      refute has_element?(view, "#quest-current-position")
    end

    render_submit(view, "move", %{
      "intervention" => %{"node_id" => "hub", "reason" => "No assignment"}
    })

    assert has_element?(view, "#flash-error", "no longer active")
    render_submit(view, "end", %{})
    assert has_element?(view, "#flash-error", "Choose a character and an action")
    assert {:ok, []} = Quests.list_interventions(c.campaign, "456", c.a.id)
  end

  test "stale tabs reject replacements and moves rather than overwriting new positions", c do
    {:ok, p} = Quests.assign(c.campaign, "456", c.a.id, c.revision.id)
    {:ok, view, _} = live(c.conn, ~p"/quests?character_id=#{c.a.id}")
    {:ok, replacement} = Quests.swap(c.campaign, "456", c.a.id, c.revision.id)
    assign_quest(view, c.revision, "Stale replacement")
    assert has_element?(view, "#flash-error", "changed in another window")
    assert has_element?(view, "#quest-current-position", "Assignment ##{replacement.id}")
    {:ok, ended} = Quests.move(c.campaign, "456", replacement.id, "end")

    render_submit(view, "move", %{
      "intervention" => %{"node_id" => "hub", "reason" => "Stale move"}
    })

    assert has_element?(view, "#flash-error", "changed in another window")
    refute has_element?(view, "#quest-move-form")
    assert Repo.get!(Progression, replacement.id) == ended
    assert Repo.get!(Progression, p.id).status == :ended
    assert {:ok, audits} = Quests.list_interventions(c.campaign, "456", c.a.id)
    refute Enum.any?(audits, &(&1.reason in ["Stale replacement", "Stale move"]))
  end

  test "an unassigned stale tab cannot replace an assignment created elsewhere", c do
    {:ok, view, _} = live(c.conn, ~p"/quests?character_id=#{c.a.id}")
    {:ok, p} = Quests.assign(c.campaign, "456", c.a.id, c.revision.id)
    assign_quest(view, c.revision, "Old unassigned editor")
    assert has_element?(view, "#flash-error", "changed in another window")
    assert Repo.get!(Progression, p.id) == p
    assert has_element?(view, "#quest-move-form")
  end

  test "resolving/review locks are visible and old open forms cannot alter frozen inputs", c do
    {:ok, p} = Quests.assign(c.campaign, "456", c.a.id, c.revision.id)
    {:ok, tick} = Ticks.open_tick(c.campaign.id)
    {:ok, view, _} = live(c.conn, ~p"/quests?character_id=#{c.a.id}")
    {:ok, %{snapshot: snapshot}} = Ticks.close_tick(c.campaign.id, tick.id)
    assign_quest(view, c.revision, "Stale open editor")
    assert has_element?(view, "#flash-error", "locked during resolution and review")
    assert has_element?(view, "#quest-locked")
    assert has_element?(view, "#quest-assign-submit[disabled]")
    assert has_element?(view, "#quest-move-submit[disabled]")
    assert has_element?(view, "#quest-end-submit[disabled]")
    {:ok, payload} = AsyncWorlds.Ticks.WorldResolver.resolve(snapshot)
    {:ok, %{draft: draft}} = Ticks.put_draft(c.campaign.id, tick.id, snapshot.revision, payload)

    for operation <- ["assign", "swap", "move", "end"] do
      render_submit(view, operation, %{
        "intervention" => %{
          "revision_id" => c.revision.id,
          "node_id" => "end",
          "reason" => "Locked request"
        }
      })

      assert has_element?(view, "#flash-error", "locked during resolution and review")
      assert {:ok, ^snapshot} = Ticks.fetch_snapshot(c.campaign.id, tick.id)
      assert Repo.get!(Progression, p.id) == p
    end

    {:ok, _} = Ticks.publish_tick(c.campaign.id, tick.id, draft.id)
    view |> element("#refresh-quests") |> render_click()
    refute has_element?(view, "#quest-locked")
    assert has_element?(view, "#quest-move-submit:not([disabled])")
  end

  test "every mount and operation enforces current DM authorization", c do
    assert {:error, {:redirect, %{to: "/login"}}} = live(build_conn(), ~p"/quests")
    assert redirected_to(get(build_conn(), ~p"/quests")) == ~p"/login"
    {:ok, view, _} = live(c.conn, ~p"/quests?character_id=#{c.a.id}")

    {:ok, _} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "123",
        dm_user_id: "458",
        public_channel_id: "789"
      })

    assign_quest(view, c.revision)
    assert_redirect(view, ~p"/login")
    assert {:ok, []} = Quests.list_interventions(c.campaign, "458", c.a.id)
  end

  test "revoked and expired sessions cannot dispatch quest controls", c do
    {:ok, view, _} = live(c.conn, ~p"/quests?character_id=#{c.a.id}")
    token = get_session(get(c.conn, ~p"/dashboard"), :web_session_token)
    :ok = WebAuth.revoke_session(token)
    assert_redirect(view, ~p"/login")
    conn = log_in_dm(build_conn(), c.campaign)
    {:ok, view, _} = live(conn, ~p"/quests?character_id=#{c.a.id}")
    Repo.update_all(AsyncWorlds.WebAuth.Session, set: [expires_at: ~U[2000-01-01 00:00:00Z]])
    assign_quest(view, c.revision)
    assert_redirect(view, ~p"/login")
    assert {:ok, []} = Quests.list_interventions(c.campaign, "456", c.a.id)
  end

  test "character profile links directly to its quest operations", c do
    {:ok, view, _} = live(c.conn, ~p"/characters")

    assert has_element?(
             view,
             "#character-quests-#{c.a.id}[href='/quests?character_id=#{c.a.id}']"
           )

    result = view |> element("#character-quests-#{c.a.id}") |> render_click()
    assert {:ok, quest_view, _} = follow_redirect(result, c.conn)
    assert has_element?(quest_view, "#quest-selected-character", "Rook")
  end
end
