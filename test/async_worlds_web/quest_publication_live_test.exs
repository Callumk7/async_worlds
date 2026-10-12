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

      assert snapshot.schema_version == 2
      {:ok, view, _} = live(c.conn, ~p"/ticks/#{tick.id}/review")
      view |> form("#publish-form", publish: %{confirm: "true"}) |> render_submit()

      if @kind == :world_only do
        assert_redirect(view, ~p"/dashboard")
        assert {:ok, %{status: :published}} = Ticks.fetch_tick(c.campaign.id, tick.id)
      else
        assert has_element?(view, "#flash-error", "Quest publication is not available yet")
        assert has_element?(view, "#tick-review")
        assert {:ok, %{status: :in_review}} = Ticks.fetch_tick(c.campaign.id, tick.id)
        assert {:error, :not_published} = Ticks.fetch_publication(c.campaign.id, tick.id)
      end
    end
  end
end
