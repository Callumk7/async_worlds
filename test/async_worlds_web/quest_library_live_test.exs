defmodule AsyncWorldsWeb.QuestLibraryLiveTest do
  use AsyncWorldsWeb.ConnCase
  use Oban.Testing, repo: AsyncWorlds.Repo
  import Phoenix.LiveViewTest
  import Ecto.Query
  import AsyncWorlds.QuestFixtures
  alias AsyncWorlds.{Campaigns, Characters, Quests, Repo, Ticks, WebAuth}
  alias AsyncWorlds.Discord.{Dispatcher, FakeAdapter}

  setup %{conn: conn} do
    {:ok, campaign} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "123",
        dm_user_id: "456",
        public_channel_id: "789"
      })

    %{conn: log_in_dm(conn, campaign), campaign: campaign}
  end

  defp new_work(view, campaign) do
    view |> element("#new-quest") |> render_click()
    {:ok, %{drafts: [work]}} = Quests.library(campaign, "456")
    assert_patch(view, "/quests/library?draft_id=#{work.id}")
    work
  end

  defp fill(view, params),
    do: view |> form("#quest-editor-form", quest: params) |> render_change()

  defp release(view),
    do: view |> form("#quest-editor-form") |> render_submit(%{"operation" => "release"})

  test "complete harbourmaster form flow saves resumes repairs releases assigns and preserves pins",
       c do
    {:ok, view, _} = live(c.conn, ~p"/quests/library")
    assert has_element?(view, "#library-drafts-empty")
    assert has_element?(view, "#library-revisions-empty")
    work = new_work(view, c.campaign)

    view
    |> form("#quest-editor-form",
      quest: %{
        name: "Meet the harbourmaster",
        content_id: "harbourmaster",
        node_0_text: "Meet the harbourmaster"
      }
    )
    |> render_submit()

    assert has_element?(view, "#flash-info", "saved")
    {:ok, resumed, _} = live(c.conn, ~p"/quests/library?draft_id=#{work.id}")
    assert has_element?(resumed, "#quest-name[value='Meet the harbourmaster']")
    assert has_element?(resumed, "#node-0-text", "Meet the harbourmaster")
    release(resumed)
    assert has_element?(resumed, "#draft-errors", "nodes[0].choices")
    resumed |> element("#add-choice-0") |> render_click()
    resumed |> element("#add-quest-node") |> render_click()
    {:ok, saved} = Quests.get_working_copy(c.campaign, "456", work.id)
    entry_id = hd(saved.definition["nodes"])["id"]
    # The freshly added ending is exposed as a human-readable destination, not an ID entry field.
    html = resumed |> element("#quest-start-node") |> render()
    options = html |> LazyHTML.from_fragment() |> LazyHTML.query("option") |> LazyHTML.to_tree()
    [{"option", _, _}, {"option", ending_attrs, _}] = options
    ending_id = ending_attrs |> Enum.into(%{}) |> Map.fetch!("value")

    fill(resumed, %{
      node_1_text: "Welcome aboard",
      node_1_ending: "true",
      node_0_choice_0_label: "Introduce yourself",
      node_0_choice_0_text: "The harbourmaster smiles",
      node_0_choice_0_destination: ending_id
    })

    # A tampered/stale destination is diagnosed, not silently replaced or published.
    render_change(resumed, "change", %{"quest" => %{"node_0_choice_0_destination" => "missing"}})
    release(resumed)
    assert has_element?(resumed, "#draft-errors", "next_node")
    assert {:ok, %{revisions: []}} = Quests.library(c.campaign, "456")
    fill(resumed, %{node_0_choice_0_destination: ending_id})
    release(resumed)
    assert has_element?(resumed, "#flash-info", "Released revision 1")
    {:ok, %{revisions: [r1]}} = Quests.library(c.campaign, "456")
    {:ok, first} = Quests.get_revision(c.campaign, "456", r1.id)
    assert first.definition["start_node"] == entry_id
    choice_id = hd(hd(first.definition["nodes"])["choices"])["id"]

    {:ok, character} =
      Characters.create_character(c.campaign, "456", %{name: "Rook", discord_user_id: "991"})

    {:ok, ops, _} = live(c.conn, ~p"/quests?character_id=#{character.id}")

    ops
    |> form("#quest-assignment-form",
      intervention: %{revision_id: to_string(r1.id), reason: "Begin the harbour story"}
    )
    |> render_submit()

    assert has_element?(ops, "#quest-current-position", "revision 1")
    fill(resumed, %{node_0_text: "An updated welcome"})
    release(resumed)
    assert has_element?(resumed, "#flash-info", "Released revision 2")
    ops |> element("#refresh-quests") |> render_click()
    assert has_element?(ops, "#quest-current-position", "revision 1")
    assert has_element?(ops, "#quest-node-text", "Meet the harbourmaster")
    {:ok, %{revisions: [r2, _]}} = Quests.library(c.campaign, "456")
    {:ok, second} = Quests.get_revision(c.campaign, "456", r2.id)
    assert hd(second.definition["nodes"])["id"] == entry_id
    assert hd(hd(second.definition["nodes"])["choices"])["id"] == choice_id

    # Offline /quest -> full submission -> close -> private preview -> publish ending.
    start_supervised!({FakeAdapter, owner: self()})
    {:ok, tick} = Ticks.open_tick(c.campaign.id)

    interaction = %{
      type: 2,
      id: 901,
      application_id: 111,
      guild_id: 123,
      member: %{user_id: 991},
      token: "offline-only",
      data: %{name: "quest"}
    }

    opts = [adapter: FakeAdapter, guild_id: "123", application_id: "111"]
    assert {:ok, payload} = Dispatcher.handle(interaction, opts)
    assert payload.content =~ "Meet the harbourmaster"

    button =
      payload.components
      |> Enum.flat_map(& &1.components)
      |> Enum.find(&String.contains?(&1.label, "Introduce yourself"))

    assert button

    assert {:ok, submitted} =
             Dispatcher.handle(
               %{
                 interaction
                 | type: 3,
                   id: 902,
                   data: %{custom_id: button.custom_id, component_type: 2}
               },
               opts
             )

    assert submitted.content =~ "Introduce yourself"
    assert {:ok, %{snapshot: snapshot}} = Ticks.close_tick(c.campaign.id, tick.id)

    assert :ok =
             perform_job(AsyncWorlds.Workers.ResolveTick, %{
               campaign_id: c.campaign.id,
               tick_id: tick.id,
               input_revision: snapshot.revision
             })

    {:ok, review, _} = live(c.conn, ~p"/ticks/#{tick.id}/review")
    assert has_element?(review, "#private-preview", "The harbourmaster smiles")
    fill(resumed, %{node_0_text: "Written during frozen review"})
    release(resumed)
    assert has_element?(resumed, "#flash-info", "Released revision 3")
    assert Repo.get!(Ticks.Snapshot, snapshot.id) == snapshot
    review |> form("#publish-form", publish: %{confirm: "true"}) |> render_submit()
    assert_redirect(review, ~p"/dashboard")
    assert {:ok, %{status: :published}} = Ticks.fetch_tick(c.campaign.id, tick.id)
    {:ok, ending_payload} = Dispatcher.handle(%{interaction | id: 903}, opts)
    assert ending_payload.content =~ "Welcome aboard"
    {:ok, %{selected: selected}} = Quests.management_state(c.campaign, "456", character.id)
    assert selected.progression == nil
    progression = Repo.get_by!(Quests.Progression, character_id: character.id, status: :completed)
    assert progression.revision_id == first.id
    assert progression.node_id == ending_id
  end

  test "stale tabs retain local work through refresh and recover separately without overwriting",
       c do
    {:ok, a, _} = live(c.conn, ~p"/quests/library")
    work = new_work(a, c.campaign)
    {:ok, b, _} = live(c.conn, ~p"/quests/library?draft_id=#{work.id}")
    fill(b, %{name: "My unsaved narrative", node_0_text: "Local text"})
    a |> element("#add-quest-node") |> render_click()
    a |> form("#quest-editor-form", quest: %{name: "Other tab"}) |> render_submit()
    b |> form("#quest-editor-form") |> render_submit()
    assert has_element?(b, "#draft-conflict")
    assert has_element?(b, "#quest-name[value='My unsaved narrative']")
    b |> element("#reload-draft") |> render_click()
    assert has_element?(b, "#quest-name[value='Other tab']")
    b |> element("#reload-draft") |> render_click()
    b |> element("#recover-draft") |> render_click()
    assert has_element?(b, "#quest-name[value='My unsaved narrative (recovered)']")
    assert has_element?(b, "#node-0-text", "Local text")
    {:ok, %{drafts: drafts}} = Quests.library(c.campaign, "456")
    assert length(drafts) == 2
    assert Enum.find(drafts, &(&1.id == work.id)).name == "Other tab"
  end

  test "a second stale save after reload preserves the original recovery snapshot", c do
    {:ok, writer, _} = live(c.conn, ~p"/quests/library")
    work = new_work(writer, c.campaign)
    {:ok, stale, _} = live(c.conn, ~p"/quests/library?draft_id=#{work.id}")
    fill(stale, %{name: "Original unsaved work", node_0_text: "Original local narrative"})

    writer |> form("#quest-editor-form", quest: %{name: "First saved change"}) |> render_submit()
    stale |> form("#quest-editor-form") |> render_submit()
    assert has_element?(stale, "#draft-conflict")
    stale |> element("#reload-draft") |> render_click()
    assert has_element?(stale, "#quest-name[value='First saved change']")

    writer |> form("#quest-editor-form", quest: %{name: "Second saved change"}) |> render_submit()
    fill(stale, %{name: "Later unsaved work", node_0_text: "Later local narrative"})
    stale |> form("#quest-editor-form") |> render_submit()
    assert has_element?(stale, "#draft-conflict")
    assert has_element?(stale, "#quest-name[value='Later unsaved work']")
    stale |> element("#reload-draft") |> render_click()
    stale |> element("#recover-draft") |> render_click()

    assert has_element?(stale, "#quest-name[value='Original unsaved work (recovered)']")
    assert has_element?(stale, "#node-0-text", "Original local narrative")
    {:ok, %{drafts: drafts}} = Quests.library(c.campaign, "456")
    assert length(drafts) == 2
    assert Enum.find(drafts, &(&1.id == work.id)).name == "Second saved change"
    recovered = Enum.find(drafts, &(&1.id != work.id))
    assert recovered.name == "Original unsaved work (recovered)"
    assert hd(recovered.definition["nodes"])["text"] == "Original local narrative"
  end

  test "same-view draft navigation keeps recovery snapshots separate and clean drafts clear", c do
    {:ok, draft_a} = Quests.create_working_copy(c.campaign, "456")
    {:ok, draft_b} = Quests.create_working_copy(c.campaign, "456")
    {:ok, view, _} = live(c.conn, ~p"/quests/library?draft_id=#{draft_a.id}")
    {:ok, writer_a, _} = live(c.conn, ~p"/quests/library?draft_id=#{draft_a.id}")
    {:ok, writer_b, _} = live(c.conn, ~p"/quests/library?draft_id=#{draft_b.id}")

    fill(view, %{name: "Original A", node_0_text: "Original A narrative"})
    writer_a |> form("#quest-editor-form", quest: %{name: "Saved A"}) |> render_submit()
    view |> form("#quest-editor-form") |> render_submit()
    assert has_element?(view, "#draft-conflict")

    view |> element("#drafts-#{draft_b.id}") |> render_click()
    assert_patch(view, "/quests/library?draft_id=#{draft_b.id}")
    refute has_element?(view, "#draft-conflict")
    refute has_element?(view, "#reload-draft")
    refute has_element?(view, "#recover-draft")

    fill(view, %{name: "Original B", node_0_text: "Original B narrative"})
    writer_b |> form("#quest-editor-form", quest: %{name: "Saved B"}) |> render_submit()
    view |> form("#quest-editor-form") |> render_submit()
    assert has_element?(view, "#draft-conflict")
    view |> element("#recover-draft") |> render_click()
    assert has_element?(view, "#quest-name[value='Original B (recovered)']")
    assert has_element?(view, "#node-0-text", "Original B narrative")
    refute has_element?(view, "#recover-draft")

    view |> element("#drafts-#{draft_a.id}") |> render_click()
    assert_patch(view, "/quests/library?draft_id=#{draft_a.id}")
    assert has_element?(view, "#quest-name[value='Saved A']")
    assert has_element?(view, "#recover-draft")
    view |> element("#reload-draft") |> render_click()
    view |> element("#recover-draft") |> render_click()
    assert has_element?(view, "#quest-name[value='Original A (recovered)']")
    assert has_element?(view, "#node-0-text", "Original A narrative")

    {:ok, %{drafts: drafts}} = Quests.library(c.campaign, "456")
    assert length(drafts) == 4
    assert Enum.find(drafts, &(&1.id == draft_a.id)).name == "Saved A"
    assert Enum.find(drafts, &(&1.id == draft_b.id)).name == "Saved B"

    for {name, text} <- [
          {"Original A (recovered)", "Original A narrative"},
          {"Original B (recovered)", "Original B narrative"}
        ] do
      recovered = Enum.find(drafts, &(&1.name == name))
      assert recovered
      assert hd(recovered.definition["nodes"])["text"] == text
    end
  end

  test "node additions stop at 100 even for forged events and the boundary draft saves", c do
    {:ok, work} = Quests.create_working_copy(c.campaign, "456")
    nodes = work.definition["nodes"] ++ Enum.map(1..98, fn _ -> Quests.Authoring.new_node() end)
    definition = Map.put(work.definition, "nodes", nodes)

    {:ok, seeded} =
      Quests.save_working_copy(c.campaign, "456", work.id, work.version, %{
        name: "Node boundary",
        content_id: "node_boundary",
        definition: definition
      })

    {:ok, view, _} = live(c.conn, ~p"/quests/library?draft_id=#{work.id}")
    assert has_element?(view, "#editor-node-98")
    refute has_element?(view, "#editor-node-99")
    refute has_element?(view, "#add-quest-node[disabled]")
    view |> element("#add-quest-node") |> render_click()
    assert has_element?(view, "#editor-node-99")

    for _ <- 1..2 do
      render_click(view, "add-node", %{})
      refute has_element?(view, "#editor-node-100")
    end

    assert has_element?(view, "#add-quest-node[disabled]")

    view
    |> form("#quest-editor-form", quest: %{node_0_text: "Still editable at the limit"})
    |> render_submit()

    assert has_element?(view, "#flash-info", "Working copy saved")
    {:ok, saved} = Quests.get_working_copy(c.campaign, "456", work.id)
    assert saved.version == seeded.version + 1
    assert length(saved.definition["nodes"]) == 100

    assert Enum.take(saved.definition["nodes"], 99) |> Enum.map(& &1["id"]) ==
             Enum.map(nodes, & &1["id"])

    assert hd(saved.definition["nodes"])["text"] == "Still editable at the limit"
  end

  test "choice additions stop at 100 even for forged events and the boundary draft saves", c do
    {:ok, work} = Quests.create_working_copy(c.campaign, "456")
    choices = Enum.map(1..99, fn _ -> Quests.Authoring.new_choice() end)
    definition = put_in(work.definition, ["nodes", Access.at(0), "choices"], choices)

    {:ok, seeded} =
      Quests.save_working_copy(c.campaign, "456", work.id, work.version, %{
        name: "Choice boundary",
        content_id: "choice_boundary",
        definition: definition
      })

    {:ok, view, _} = live(c.conn, ~p"/quests/library?draft_id=#{work.id}")
    assert has_element?(view, "#editor-choice-0-98")
    refute has_element?(view, "#editor-choice-0-99")
    refute has_element?(view, "#add-choice-0[disabled]")
    view |> element("#add-choice-0") |> render_click()
    assert has_element?(view, "#editor-choice-0-99")

    for _ <- 1..2 do
      render_click(view, "add-choice", %{"index" => "0"})
      refute has_element?(view, "#editor-choice-0-100")
    end

    assert has_element?(view, "#add-choice-0[disabled]")

    view
    |> form("#quest-editor-form", quest: %{node_0_choice_99_label: "Last permitted choice"})
    |> render_submit()

    assert has_element?(view, "#flash-info", "Working copy saved")
    {:ok, saved} = Quests.get_working_copy(c.campaign, "456", work.id)
    assert saved.version == seeded.version + 1
    saved_choices = hd(saved.definition["nodes"])["choices"]
    assert length(saved_choices) == 100
    assert Enum.take(saved_choices, 99) == choices
    assert List.last(saved_choices)["label"] == "Last permitted choice"
  end

  test "imported revisions have explicit read-only unsupported controls and release intact", c do
    {:ok, revision} =
      Quests.create_quest(
        c.campaign,
        "456",
        %{name: "Imported", content_id: "imported"},
        replace_choice(definition(), rolled())
      )

    {:ok, view, _} = live(c.conn, ~p"/quests/library")
    view |> element("#edit-revision-#{revision.id}") |> render_click()
    assert has_element?(view, "#draft-identity", "Base revision v1")
    assert has_element?(view, "#protected-choice-0-0")
    refute has_element?(view, "#choice-0-0-label")
    assert has_element?(view, "#node-0-ending[disabled]")
    fill(view, %{name: "Edited imported story", node_0_text: "Revised narrative"})
    release(view)
    {:ok, %{revisions: [next, _]}} = Quests.library(c.campaign, "456")
    {:ok, next} = Quests.get_revision(c.campaign, "456", next.id)
    assert hd(next.definition["nodes"])["choices"] == hd(revision.definition["nodes"])["choices"]
  end

  test "forged IDs and browser actor/campaign fields never select foreign content", c do
    {:ok, other} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "124",
        dm_user_id: "457",
        public_channel_id: "790"
      })

    {:ok, foreign} = Quests.create_working_copy(other, "457")

    {:ok, revision} =
      Quests.create_quest(other, "457", %{name: "Foreign", content_id: "foreign"}, definition())

    {:ok, view, _} = live(c.conn, ~p"/quests/library?draft_id=#{foreign.id}")
    refute has_element?(view, "#quest-editor-form")

    render_click(view, "edit", %{
      "id" => revision.id,
      "campaign_id" => other.id,
      "actor_id" => "457"
    })

    refute has_element?(view, "#quest-editor-form")
    work = new_work(view, c.campaign)

    render_submit(view, "save", %{
      "quest" => %{
        "name" => "Local",
        "campaign_id" => other.id,
        "actor_id" => "457",
        "id" => foreign.id
      }
    })

    {:ok, saved} = Quests.get_working_copy(c.campaign, "456", work.id)
    assert saved.name == "Local"
    {:ok, unchanged} = Quests.get_working_copy(other, "457", foreign.id)
    assert unchanged.name == ""
  end

  test "anonymous and newly non-DM mounts cannot read the library", c do
    assert {:error, {:redirect, %{to: "/login"}}} = live(build_conn(), ~p"/quests/library")
    Repo.update!(Ecto.Changeset.change(c.campaign, dm_user_id: "999"))
    assert {:error, {:redirect, %{to: "/login"}}} = live(c.conn, ~p"/quests/library")
  end

  test "malformed browser form payloads cannot crash or replace definitions", c do
    {:ok, view, _} = live(c.conn, ~p"/quests/library")
    work = new_work(view, c.campaign)

    for payload <- [[], nil, "unexpected"] do
      render_change(view, "change", %{"quest" => payload})
      render_submit(view, "save", %{"quest" => payload})
      render_submit(view, "release", %{"quest" => payload})
      assert has_element?(view, "#quest-editor-form")
    end

    render_change(view, "change", %{
      "quest" => %{"name" => [], "node_0_text" => %{}, "start_node" => nil}
    })

    assert has_element?(view, "#quest-name[value='']")
    assert {:ok, ^work} = Quests.get_working_copy(c.campaign, "456", work.id)
  end

  test "revoked expired and changed-DM sessions cannot save from stale tabs", c do
    for mode <- [:revoked, :expired, :dm_changed] do
      conn = log_in_dm(c.conn, c.campaign)
      {:ok, view, _} = live(conn, ~p"/quests/library")
      view |> element("#new-quest") |> render_click()
      token = get_session(get(conn, ~p"/dashboard"), :web_session_token)
      {:ok, scope} = WebAuth.authorize_session(token)

      case mode do
        :revoked ->
          WebAuth.revoke_session(token)

        :expired ->
          Repo.update_all(from(s in WebAuth.Session, where: s.id == ^scope.session_id),
            set: [expires_at: DateTime.add(DateTime.utc_now(), -60, :second)]
          )

        :dm_changed ->
          Repo.update!(Ecto.Changeset.change(c.campaign, dm_user_id: "999"))
      end

      if mode == :revoked do
        assert_redirect(view, "/login")
      else
        render_submit(view, "save", %{"quest" => %{"name" => "Forbidden"}})
        assert_redirect(view, "/login")
      end

      refute Repo.exists?(from d in Quests.WorkingCopy, where: d.name == "Forbidden")
    end
  end
end
