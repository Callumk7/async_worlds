defmodule AsyncWorldsWeb.PublicSummaryLiveTest do
  use AsyncWorldsWeb.ConnCase

  import Phoenix.LiveViewTest
  import Ecto.Query
  import AsyncWorlds.QuestFixtures
  alias AsyncWorlds.{Campaigns, Characters, Quests, Repo, WebAuth}

  setup %{conn: conn} do
    {:ok, campaign} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "123",
        dm_user_id: "456",
        public_channel_id: "789"
      })

    {:ok, revision} =
      Quests.create_quest(
        campaign,
        "456",
        %{name: "Secret investigation", content_id: "harbor"},
        definition()
      )

    {:ok, work} = Quests.create_working_copy(campaign, "456", revision.id)
    %{conn: log_in_dm(conn, campaign), campaign: campaign, work: work, revision: revision}
  end

  test "summary saves, reopens, releases and clears without repinning characters", c do
    {:ok, character} =
      Characters.create_character(c.campaign, "456", %{name: "Scout", discord_user_id: "991"})

    {:ok, position} = Quests.assign(c.campaign, "456", character.id, c.revision.id)
    {:ok, view, _} = live(c.conn, ~p"/quests/library?draft_id=#{c.work.id}")

    assert has_element?(
             view,
             "#node-0-public-summary[aria-describedby='node-0-public-summary-help']"
           )

    assert has_element?(view, "#node-0-public-summary-help")

    view
    |> form("#quest-editor-form", quest: %{node_0_public_summary: "Investigating the harbour"})
    |> render_submit()

    assert has_element?(view, "#flash-info", "saved")
    {:ok, resumed, _} = live(c.conn, ~p"/quests/library?draft_id=#{c.work.id}")
    assert has_element?(resumed, "#node-0-public-summary", "Investigating the harbour")
    resumed |> form("#quest-editor-form") |> render_submit(%{"operation" => "release"})
    assert has_element?(resumed, "#flash-info", "Released revision 2")
    {:ok, saved} = Quests.get_working_copy(c.campaign, "456", c.work.id)
    {:ok, released} = Quests.get_revision(c.campaign, "456", saved.base_revision_id)
    assert hd(released.definition["nodes"])["public_summary"] == "Investigating the harbour"
    assert Repo.get!(Quests.Progression, position.id) == position
    assert Repo.get!(Quests.Revision, c.revision.id).definition == definition()

    assert {:ok, [%{summary: "A quest decision is required."}]} =
             Quests.public_activities(c.campaign, "456")

    resumed |> form("#quest-editor-form", quest: %{node_0_public_summary: ""}) |> render_submit()
    {:ok, cleared} = Quests.get_working_copy(c.campaign, "456", c.work.id)
    refute Map.has_key?(hd(cleared.definition["nodes"]), "public_summary")
  end

  test "oversized summary retains local input and blocks persistence and release", c do
    {:ok, view, _} = live(c.conn, ~p"/quests/library?draft_id=#{c.work.id}")
    oversized = String.duplicate("é", 501)

    for operation <- ["save", "release"] do
      view
      |> form("#quest-editor-form", quest: %{node_0_public_summary: oversized})
      |> render_submit(%{"operation" => operation})

      assert has_element?(view, "#draft-errors", "nodes[0].public_summary")
      assert has_element?(view, "#node-0-public-summary", oversized)
      assert {:ok, work} = Quests.get_working_copy(c.campaign, "456", c.work.id)
      assert work == c.work
    end

    assert Repo.aggregate(Quests.Revision, :count) == 1
  end

  test "stale summary save retains unsaved work but cannot overwrite a newer summary", c do
    {:ok, first, _} = live(c.conn, ~p"/quests/library?draft_id=#{c.work.id}")
    {:ok, stale, _} = live(c.conn, ~p"/quests/library?draft_id=#{c.work.id}")

    first
    |> form("#quest-editor-form", quest: %{node_0_public_summary: "First summary"})
    |> render_submit()

    stale
    |> form("#quest-editor-form", quest: %{node_0_public_summary: "Stale summary"})
    |> render_submit()

    assert has_element?(stale, "#flash-error", "changed")
    assert has_element?(stale, "#node-0-public-summary", "Stale summary")
    {:ok, persisted} = Quests.get_working_copy(c.campaign, "456", c.work.id)
    assert hd(persisted.definition["nodes"])["public_summary"] == "First summary"
  end

  test "foreign working copies and forged form IDs cannot change public content", c do
    {:ok, other} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "124",
        dm_user_id: "457",
        public_channel_id: "790"
      })

    {:ok, foreign} = Quests.create_working_copy(other, "457")
    {:ok, denied, _} = live(c.conn, ~p"/quests/library?draft_id=#{foreign.id}")
    refute has_element?(denied, "#quest-editor-form")
    {:ok, view, _} = live(c.conn, ~p"/quests/library?draft_id=#{c.work.id}")

    render_submit(view, "save", %{
      "quest" => %{
        "id" => foreign.id,
        "campaign_id" => other.id,
        "actor_id" => "457",
        "node_0_public_summary" => "Local summary"
      }
    })

    assert {:ok, ^foreign} = Quests.get_working_copy(other, "457", foreign.id)
    {:ok, local} = Quests.get_working_copy(c.campaign, "456", c.work.id)
    assert hd(local.definition["nodes"])["public_summary"] == "Local summary"
  end

  test "expired sessions cannot save a public summary", c do
    {:ok, view, _} = live(c.conn, ~p"/quests/library?draft_id=#{c.work.id}")
    token = get_session(get(c.conn, ~p"/dashboard"), :web_session_token)
    {:ok, scope} = WebAuth.authorize_session(token)

    Repo.update_all(from(s in WebAuth.Session, where: s.id == ^scope.session_id),
      set: [expires_at: DateTime.add(DateTime.utc_now(), -60, :second)]
    )

    render_submit(view, "save", %{"quest" => %{"node_0_public_summary" => "Forbidden"}})
    assert_redirect(view, "/login")
    assert Repo.get!(Quests.WorkingCopy, c.work.id) == c.work
  end
end
