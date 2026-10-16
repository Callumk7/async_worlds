defmodule AsyncWorldsWeb.MembershipLiveTest do
  use AsyncWorldsWeb.ConnCase
  import Phoenix.LiveViewTest

  alias AsyncWorlds.{
    Campaigns,
    Characters,
    Factions,
    LinkHistory,
    Memberships,
    Quests,
    Repo,
    Ticks
  }

  alias AsyncWorlds.Characters.Character
  alias AsyncWorlds.Factions.Membership

  setup %{conn: conn} do
    {:ok, campaign} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "123",
        dm_user_id: "456",
        public_channel_id: "789"
      })

    scope = %{campaign: campaign, discord_user_id: "456"}

    {:ok, character} =
      Characters.create_character(campaign, "456", %{name: "Mira", discord_user_id: "555"})

    {:ok, faction} = Factions.create_faction(scope, %{name: "Explorers"})
    {:ok, other_character} = Characters.create_character(campaign, "456", %{name: "Other"})
    {:ok, other_faction} = Factions.create_faction(scope, %{name: "Other guild"})

    {:ok, foreign_campaign} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "124",
        dm_user_id: "457",
        public_channel_id: "790"
      })

    foreign_scope = %{campaign: foreign_campaign, discord_user_id: "457"}

    {:ok, foreign_character} =
      Characters.create_character(foreign_campaign, "457", %{name: "Foreign character"})

    {:ok, foreign_faction} = Factions.create_faction(foreign_scope, %{name: "Foreign faction"})

    %{
      conn: log_in_dm(conn, campaign),
      scope: scope,
      character: character,
      faction: faction,
      other_character: other_character,
      other_faction: other_faction,
      foreign_character: foreign_character,
      foreign_faction: foreign_faction,
      foreign_scope: foreign_scope
    }
  end

  for type <- [:faction, :character] do
    @panel_type type

    test "#{type} panel joins, edits, clears, leaves and rejoins without gameplay side effects",
         c do
      {:ok, character} =
        Characters.set_flag(c.scope.campaign, "456", c.character.id, "ready", %{
          "type" => "boolean",
          "value" => true,
          "player_visible" => false
        })

      {:ok, revision} =
        Quests.create_quest(
          c.scope.campaign,
          "456",
          %{content_id: "quest", name: "Quest"},
          AsyncWorlds.QuestFixtures.definition()
        )

      {:ok, progression} = Quests.assign(c.scope.campaign, "456", character.id, revision.id)
      {:ok, tick} = Ticks.open_tick(c.scope.campaign.id)
      {:ok, state} = Quests.Submissions.player_state("123", "555")
      {:ok, _} = Quests.Submissions.submit("123", "555", state.identity, "loop")
      submission = Repo.get_by!(Quests.Submission, tick_id: tick.id, character_id: character.id)
      character = Repo.get!(Character, character.id)
      deliveries = Repo.all(AsyncWorlds.Deliveries.Delivery)
      jobs = Repo.all(Oban.Job)

      view = open_panel(c, @panel_type)
      assert has_element?(view, "#memberships-empty")
      assert has_element?(view, "#memberships[phx-update=stream]")
      join(view, target(c, @panel_type), "Scout")
      {:ok, [membership]} = Memberships.list_character_affiliations(c.scope, character.id)

      assert has_element?(
               view,
               "#memberships-#{membership.id}",
               if(@panel_type == :faction, do: character.name, else: c.faction.name)
             )

      assert has_element?(view, "#membership-role-#{membership.id}[value=Scout]")
      refute has_element?(view, "#memberships-empty:only-child")
      assert has_element?(view, "#membership-leave-#{membership.id}[data-confirm]")

      view
      |> form("#membership-role-form-#{membership.id}", membership: %{role: "Captain"})
      |> render_submit()

      assert Repo.get!(Membership, membership.id).role == "Captain"

      view
      |> form("#membership-role-form-#{membership.id}", membership: %{role: " \u00A0"})
      |> render_submit()

      assert Repo.get!(Membership, membership.id).role == nil
      view |> element("#membership-leave-#{membership.id}") |> render_click()
      refute Repo.get(Membership, membership.id)
      assert has_element?(view, "#memberships-empty")
      join(view, target(c, @panel_type), "Returned")
      {:ok, [rejoined]} = Memberships.list_character_affiliations(c.scope, character.id)
      assert rejoined.id != membership.id
      assert has_element?(view, "#memberships-#{rejoined.id}")

      assert {:ok, %{items: changes}} =
               LinkHistory.list_changes(c.scope, entity: {"character", character.id})

      assert Enum.map(changes, & &1.after) == [
               state(c, "Scout"),
               state(c, "Captain"),
               state(c, nil),
               nil,
               state(c, "Returned")
             ]

      assert Enum.all?(changes, &(&1.tick_number == tick.number and &1.actor_id == "456"))
      assert Repo.get!(Character, character.id) == character
      assert Repo.get!(Quests.Progression, progression.id) == progression
      assert Repo.get!(Quests.Submission, submission.id) == submission
      assert Repo.get!(Quests.Revision, revision.id) == revision
      assert Repo.all(AsyncWorlds.Deliveries.Delivery) == deliveries
      assert Repo.all(Oban.Job) == jobs
    end

    test "#{type} panel validates joins and role edits without extra history", c do
      view = open_panel(c, @panel_type)

      render_submit(view, "membership_join", %{
        "membership" => %{
          "target_id" => target(c, @panel_type),
          "role" => String.duplicate("x", 201)
        }
      })

      assert has_element?(view, "#membership-error")
      assert has_element?(view, "#membership-join-form .text-error")
      assert {:ok, []} = Memberships.list_faction_members(c.scope, c.faction.id)
      assert {:ok, %{items: []}} = LinkHistory.list_changes(c.scope)
      join(view, target(c, @panel_type), "Scout")
      {:ok, [membership]} = Memberships.list_faction_members(c.scope, c.faction.id)
      join(view, target(c, @panel_type), "Duplicate")
      assert has_element?(view, "#membership-error")

      render_submit(view, "membership_role", %{
        "id" => membership.id,
        "membership" => %{"role" => "bad" <> <<0>>}
      })

      assert has_element?(view, "#membership-role-form-#{membership.id} .text-error")
      assert Repo.get!(Membership, membership.id).role == "Scout"
      assert {:ok, %{items: [_]}} = LinkHistory.list_changes(c.scope)
    end

    test "#{type} panel rejects missing and foreign targets and pins its endpoint", c do
      view = open_panel(c, @panel_type)

      foreign_id =
        if @panel_type == :faction, do: c.foreign_character.id, else: c.foreign_faction.id

      refute has_element?(view, "#membership-target option[value='#{foreign_id}']")

      for id <- [foreign_id, -1, "bad", %{}] do
        render_submit(view, "membership_join", %{"membership" => %{"target_id" => id}})
        assert has_element?(view, "#flash-error")
        assert {:ok, []} = Memberships.list_faction_members(c.scope, c.faction.id)
        # Faction not-found clears its editor; reopen for the next attempt.
        view |> element("#edit-#{@panel_type}-#{c[@panel_type].id}") |> render_click()
      end

      render_submit(view, "membership_join", %{
        "membership" => %{
          "target_id" => target(c, @panel_type),
          "role" => "Scout",
          "campaign_id" => c.foreign_scope.campaign.id,
          "character_id" => c.foreign_character.id,
          "faction_id" => c.foreign_faction.id,
          "id" => -1,
          "discord_user_id" => "457",
          "flags" => %{"admin" => true}
        }
      })

      {:ok, [membership]} = Memberships.list_faction_members(c.scope, c.faction.id)
      assert membership.character_id == c.character.id
      assert membership.faction_id == c.faction.id
      assert membership.campaign_id == c.scope.campaign.id

      render_submit(view, "membership_role", %{
        "id" => membership.id,
        "membership" => %{
          "role" => "Captain",
          "character_id" => c.other_character.id,
          "faction_id" => c.other_faction.id
        }
      })

      assert Repo.get!(Membership, membership.id).character_id == c.character.id
      assert Repo.get!(Membership, membership.id).faction_id == c.faction.id
      assert Repo.get!(Membership, membership.id).role == "Captain"
    end

    test "#{type} panel cannot edit or leave memberships outside the selected endpoint", c do
      {:ok, unrelated} =
        Memberships.join(c.scope, c.other_character.id, c.other_faction.id, %{role: "Unrelated"})

      {:ok, foreign} =
        Memberships.join(c.foreign_scope, c.foreign_character.id, c.foreign_faction.id)

      view = open_panel(c, @panel_type)

      for id <- [unrelated.id, foreign.id, -1, %{}],
          event <- ["membership_role", "membership_leave"] do
        render_submit(view, event, %{"id" => id, "membership" => %{"role" => "Forged"}})
        assert has_element?(view, "#flash-error")
        view |> element("#edit-#{@panel_type}-#{c[@panel_type].id}") |> render_click()
      end

      assert Repo.get!(Membership, unrelated.id).role == "Unrelated"
      assert Repo.get!(Membership, foreign.id).role == nil
      assert {:ok, %{items: [_]}} = LinkHistory.list_changes(c.scope)
    end

    test "#{type} panel rejects removed memberships and resets when switching records", c do
      {:ok, membership} = Memberships.join(c.scope, c.character.id, c.faction.id)
      view = open_panel(c, @panel_type)
      {:ok, _} = Memberships.leave(c.scope, membership.id)

      render_submit(view, "membership_role", %{
        "id" => membership.id,
        "membership" => %{"role" => "Gone"}
      })

      assert has_element?(view, "#flash-error")
      view |> element("#edit-#{@panel_type}-#{c[@panel_type].id}") |> render_click()
      assert has_element?(view, "#memberships-empty")
      join(view, target(c, @panel_type), "Scout")

      view
      |> element("#edit-#{@panel_type}-#{other_endpoint(c, @panel_type).id}")
      |> render_click()

      assert has_element?(view, "#memberships-empty")
      view |> element("#new-#{@panel_type}") |> render_click()
      refute has_element?(view, "#membership-panel")

      render_submit(view, "membership_join", %{
        "membership" => %{"target_id" => target(c, @panel_type)}
      })

      assert {:ok, [_]} = Memberships.list_faction_members(c.scope, c.faction.id)
    end

    test "#{type} membership events freshly authorize even after the event hook", c do
      {:ok, membership} =
        Memberships.join(c.scope, c.character.id, c.faction.id, %{role: "Private"})

      module =
        if @panel_type == :faction,
          do: AsyncWorldsWeb.FactionLive,
          else: AsyncWorldsWeb.CharacterLive

      socket =
        %Phoenix.LiveView.Socket{
          private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}, live_temp: %{}},
          assigns: %{__changed__: %{}, flash: %{}}
        }
        |> Phoenix.Component.assign(:current_scope, c.scope)

      {:ok, socket} = module.mount(%{}, %{}, socket)
      {:noreply, socket} = module.handle_event("edit", %{"id" => c[@panel_type].id}, socket)
      Repo.update!(Ecto.Changeset.change(c.scope.campaign, dm_user_id: "999"))

      for event <- ["membership_join", "membership_role", "membership_leave"] do
        {:noreply, rejected} =
          module.handle_event(
            event,
            %{
              "id" => membership.id,
              "membership" => %{"target_id" => target(c, @panel_type), "role" => "No"}
            },
            socket
          )

        assert {:redirect, %{to: "/login"}} = rejected.redirected
        assert rejected.assigns.editing == nil
        assert rejected.assigns.membership_entity == nil
        assert rejected.assigns.membership_options == []
        assert rejected.assigns.membership_form[:role].value == ""
        assert Repo.get!(Membership, membership.id).role == "Private"
      end
    end

    test "#{type} membership controls require an authenticated DM session", c do
      path = if @panel_type == :faction, do: ~p"/factions", else: ~p"/characters"
      assert {:error, {:redirect, %{to: "/login"}}} = live(build_conn(), path)
      view = open_panel(c, @panel_type)
      Repo.update_all(AsyncWorlds.WebAuth.Session, set: [expires_at: ~U[2000-01-01 00:00:00Z]])

      render_submit(view, "membership_join", %{
        "membership" => %{"target_id" => target(c, @panel_type)}
      })

      assert_redirect(view, ~p"/login")
      assert {:ok, []} = Memberships.list_faction_members(c.scope, c.faction.id)
    end
  end

  defp open_panel(c, type) do
    path = if type == :faction, do: ~p"/factions", else: ~p"/characters"
    {:ok, view, _} = live(c.conn, path)
    refute has_element?(view, "#membership-panel")
    view |> element("#edit-#{type}-#{c[type].id}") |> render_click()
    assert has_element?(view, "#membership-panel")
    view
  end

  defp other_endpoint(c, :faction), do: c.other_faction
  defp other_endpoint(c, :character), do: c.other_character
  defp target(c, :faction), do: c.character.id
  defp target(c, :character), do: c.faction.id

  defp join(view, target, role),
    do:
      view
      |> form("#membership-join-form", membership: %{target_id: target, role: role})
      |> render_submit()

  defp state(c, role),
    do: %{"character_id" => c.character.id, "faction_id" => c.faction.id, "role" => role}
end
