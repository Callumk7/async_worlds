defmodule AsyncWorldsWeb.CharacterLiveTest do
  use AsyncWorldsWeb.ConnCase
  import Phoenix.LiveViewTest
  import Ecto.Query
  alias AsyncWorlds.{Campaigns, Characters, Repo, WebAuth}
  alias AsyncWorlds.Characters.Character

  setup %{conn: conn} do
    {:ok, campaign} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "123",
        dm_user_id: "456",
        public_channel_id: "789"
      })

    %{campaign: campaign, conn: log_in_dm(conn, campaign)}
  end

  test "authorization revoked after the event hook clears private state and redirects", c do
    {:ok, character} =
      Characters.create_character(c.campaign, "456", %{name: "Private", discord_user_id: "999"})

    socket =
      %Phoenix.LiveView.Socket{
        private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}, live_temp: %{}},
        assigns: %{__changed__: %{}, flash: %{}}
      }
      |> Phoenix.Component.assign(:current_scope, %{
        campaign: c.campaign,
        discord_user_id: "456"
      })

    {:ok, socket} = AsyncWorldsWeb.CharacterLive.mount(%{}, %{}, socket)

    {:noreply, socket} =
      AsyncWorldsWeb.CharacterLive.handle_event("edit", %{"id" => character.id}, socket)

    assert socket.assigns.editing.name == "Private"

    # Simulates revocation between LiveAuth's event check and the domain read.
    {:ok, _} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "123",
        dm_user_id: "555",
        public_channel_id: "789"
      })

    for event <- ["new_flag", "save"] do
      params = if event == "save", do: %{"character" => %{"name" => "Forged"}}, else: %{}
      {:noreply, rejected} = AsyncWorldsWeb.CharacterLive.handle_event(event, params, socket)
      assert {:redirect, %{to: "/login"}} = rejected.redirected
      assert rejected.assigns.editing == nil
      assert rejected.assigns.connected == nil
      assert rejected.assigns.form[:name].value == nil
      assert Repo.get!(Character, character.id).name == "Private"
    end
  end

  test "successful profile and flag writes stop reloading after authorization-loss redirect", c do
    {:ok, character} =
      Characters.create_character(c.campaign, "456", %{name: "Private", discord_user_id: "999"})

    for event <- ["save", "set_flag"] do
      {:ok, campaign} =
        Campaigns.setup_campaign(%{
          discord_guild_id: "123",
          dm_user_id: "456",
          public_channel_id: "789"
        })

      socket =
        %Phoenix.LiveView.Socket{
          private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}, live_temp: %{}},
          assigns: %{__changed__: %{}, flash: %{}}
        }
        |> Phoenix.Component.assign(:current_scope, %{campaign: campaign, discord_user_id: "456"})

      {:ok, socket} = AsyncWorldsWeb.CharacterLive.mount(%{}, %{}, socket)

      {:noreply, socket} =
        AsyncWorldsWeb.CharacterLive.handle_event("edit", %{"id" => character.id}, socket)

      handler = {__MODULE__, event, make_ref()}
      owner = self()
      # Revoke immediately after the authorized write, before its connected-view reload.
      :telemetry.attach(
        handler,
        [:async_worlds, :repo, :query],
        fn _, _, metadata, _ ->
          if self() == owner and String.starts_with?(metadata.query, "UPDATE \"characters\"") do
            Repo.update_all(
              from(c in AsyncWorlds.Campaigns.Campaign, where: c.id == ^campaign.id),
              set: [dm_user_id: "555"]
            )
          end
        end,
        nil
      )

      try do
        params =
          if event == "save",
            do: %{"character" => %{"name" => "Updated"}},
            else: %{
              "flag" => %{
                "key" => "ready",
                "type" => "boolean",
                "value" => "true",
                "player_visible" => "false"
              }
            }

        {:noreply, rejected} = AsyncWorldsWeb.CharacterLive.handle_event(event, params, socket)
        assert {:redirect, %{to: "/login"}} = rejected.redirected
        assert rejected.assigns.editing == nil
        assert rejected.assigns.connected == nil
        saved = Repo.get!(Character, character.id)

        if event == "save",
          do: assert(saved.name == "Updated"),
          else: assert(saved.flags["ready"]["value"] == true)

        {:noreply, again} =
          AsyncWorldsWeb.CharacterLive.handle_event(
            "save",
            %{"character" => %{"name" => "Blocked"}},
            rejected
          )

        assert again.redirected == rejected.redirected
      after
        :telemetry.detach(handler)
      end
    end
  end

  test "DM bootstraps, edits and manages typed flag visibility through shared APIs", c do
    {:ok, view, _} = live(c.conn, ~p"/characters")
    assert has_element?(view, "#characters-empty")

    view
    |> form("#character-form", character: %{name: "Rook", discord_user_id: "0999"})
    |> render_submit()

    assert has_element?(view, "#character-form .text-error")
    assert {:ok, []} = Characters.list_characters(c.campaign, "456")

    view
    |> form("#character-form", character: %{name: "Rook", discord_user_id: "999"})
    |> render_submit()

    {:ok, [character]} = Characters.list_characters(c.campaign, "456")
    assert has_element?(view, "#edit-character-#{character.id}")
    assert has_element?(view, "#flag-editor")

    view |> form("#character-form", character: %{name: "Captain Rook"}) |> render_submit()
    assert Repo.get!(Character, character.id).name == "Captain Rook"

    view |> form("#flag-form", flag: %{type: "integer"}) |> render_change()

    view
    |> form("#flag-form",
      flag: %{key: "debt", type: "integer", value: "2.5", player_visible: "true"}
    )
    |> render_submit()

    assert has_element?(view, "#flash-error")
    assert Repo.get!(Character, character.id).flags == %{}

    view
    |> form("#flag-form",
      flag: %{key: "debt", type: "integer", value: "2", player_visible: "false"}
    )
    |> render_submit()

    assert has_element?(view, "#flag-debt")
    assert {:ok, %{flags: %{}}} = Characters.player_character("123", "999")

    view |> element("#edit-flag-debt") |> render_click()
    assert has_element?(view, "#flag_key[readonly]")

    view
    |> form("#flag-form",
      flag: %{type: "integer", value: "3", player_visible: "true"}
    )
    |> render_submit()

    assert {:ok, %{flags: %{"debt" => %{"value" => 3}}}} =
             Characters.player_character("123", "999")

    view |> element("#clear-flag-debt") |> render_click()
    refute has_element?(view, "#flag-debt")
    assert Repo.get!(Character, character.id).flags == %{}

    view |> element("#new-character") |> render_click()
    refute has_element?(view, "#flag-editor")

    view
    |> form("#character-form", character: %{name: "Duplicate", discord_user_id: "999"})
    |> render_submit()

    assert has_element?(view, "#character-form .text-error")
    assert {:ok, [_]} = Characters.list_characters(c.campaign, "456")
    view |> element("#edit-character-#{character.id}") |> render_click()
    assert has_element?(view, "#flag-form")
  end

  test "accountless characters can be created and their destination is explicit", c do
    {:ok, view, _} = live(c.conn, ~p"/characters")

    for name <- ["A", "B"] do
      view |> element("#new-character") |> render_click()

      view
      |> form("#character-form", character: %{name: name, discord_user_id: ""})
      |> render_submit()
    end

    {:ok, characters} = Characters.list_characters(c.campaign, "456")
    assert length(characters) == 2

    for character <- characters do
      assert is_nil(character.discord_user_id)
      assert has_element?(view, "#character-destination-#{character.id}", "DM-controlled")
    end
  end

  test "NUL profile and ordinary flag input is rejected without crashing the editor", c do
    {:ok, character} =
      Characters.create_character(c.campaign, "456", %{name: "Rook", discord_user_id: "999"})

    {:ok, view, _} = live(c.conn, ~p"/characters")
    view |> element("#edit-character-#{character.id}") |> render_click()

    for name <- ["bad\u0000name", "a" <> String.duplicate("\u0301", 300)] do
      render_submit(view, "save", %{
        "character" => %{"name" => name, "discord_user_id" => "999"}
      })

      assert has_element?(view, "#character-form .text-error")
      assert Repo.get!(Character, character.id) == character
    end

    view |> form("#flag-form", flag: %{type: "string"}) |> render_change()

    view
    |> form("#flag-form",
      flag: %{key: "nul", type: "string", value: <<0>>, player_visible: "true"}
    )
    |> render_submit()

    assert has_element?(view, "#flash-error")
    assert has_element?(view, "#edit-character-#{character.id}")
    assert Repo.get!(Character, character.id) == character
    assert {:ok, %{flags: %{}}} = Characters.player_character("123", "999")
  end

  test "forged cross-campaign IDs and posted ownership/flags cannot grant access", c do
    {:ok, other} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "124",
        dm_user_id: "457",
        public_channel_id: "790"
      })

    {:ok, foreign} =
      Characters.create_character(other, "457", %{name: "Foreign", discord_user_id: "999"})

    {:ok, view, _} = live(c.conn, ~p"/characters")
    render_click(view, "edit", %{"id" => to_string(foreign.id)})
    assert has_element?(view, "#flash-error")
    refute has_element?(view, "#flag-editor")

    render_submit(view, "save", %{
      "character" => %{
        "name" => "Own",
        "discord_user_id" => "999",
        "campaign_id" => other.id,
        "flags" => %{"forged" => %{}}
      }
    })

    {:ok, [own]} = Characters.list_characters(c.campaign, "456")
    assert own.flags == %{}
    assert own.campaign_id == c.campaign.id
    assert Repo.get!(Character, foreign.id) == foreign
    view |> element("#edit-character-#{own.id}") |> render_click()
    assert has_element?(view, "#flag-editor")
    render_click(view, "edit", %{"id" => to_string(foreign.id)})
    refute has_element?(view, "#flag-editor")
    refute has_element?(view, "#connected-character")
  end

  test "multiline imported strings retain CRLF on visibility edits and support changed text", c do
    original = "First\r\nSecond\rThird\n\"Captain\""

    {:ok, character} =
      Characters.create_character(c.campaign, "456", %{name: "Rook", discord_user_id: "999"})

    {:ok, _} =
      Characters.set_flag(c.campaign, "456", character.id, "note", %{
        "type" => "string",
        "value" => original,
        "player_visible" => false
      })

    {:ok, view, _} = live(c.conn, ~p"/characters?character_id=#{character.id}")
    view |> element("#edit-flag-note") |> render_click()
    assert has_element?(view, "textarea#flag_value")
    normalized = "First\nSecond\nThird\n\"Captain\""

    view
    |> form("#flag-form", flag: %{value: normalized, player_visible: "true"})
    |> render_change()

    view
    |> form("#flag-form", flag: %{value: normalized, player_visible: "true"})
    |> render_submit()

    assert Repo.get!(Character, character.id).flags["note"]["value"] == original

    assert {:ok, %{flags: %{"note" => %{"value" => ^original}}}} =
             Characters.player_character("123", "999")

    view |> element("#edit-flag-note") |> render_click()
    changed = "Changed\n\"Captain\""
    view |> form("#flag-form", flag: %{value: changed, player_visible: "true"}) |> render_submit()
    assert Repo.get!(Character, character.id).flags["note"]["value"] == changed
  end

  test "plain quoted strings edit existing keys without trusting posted keys or IDs", c do
    {:ok, character} =
      Characters.create_character(c.campaign, "456", %{name: "Rook", discord_user_id: "999"})

    {:ok, view, _} = live(c.conn, ~p"/characters?character_id=#{character.id}")
    view |> form("#flag-form", flag: %{type: "string"}) |> render_change()

    view
    |> form("#flag-form",
      flag: %{key: "title", value: ~s(The "Captain"), player_visible: "false"}
    )
    |> render_submit()

    view |> element("#edit-flag-title") |> render_click()
    assert has_element?(view, "#flag_key[readonly][value=title]")

    render_submit(view, "set_flag", %{
      "flag" => %{
        "key" => "forged",
        "type" => "string",
        "value" => ~s(A "new" title),
        "player_visible" => "true",
        "character_id" => -1,
        "campaign_id" => -1,
        "actor_id" => "555"
      }
    })

    assert {:ok, %{flags: %{"title" => %{"value" => ~s(A "new" title)}}}} =
             Characters.player_character("123", "999")

    value_element = view |> element("#flag-value-title") |> render()
    assert value_element =~ "whitespace-pre-wrap"
    assert value_element |> LazyHTML.from_fragment() |> LazyHTML.text() == ~s(A "new" title)
    refute Map.has_key?(Repo.get!(Character, character.id).flags, "forged")
  end

  test "two tabs retain local input but reject stale profile, flag and clear even after ABA", c do
    {:ok, character} =
      Characters.create_character(c.campaign, "456", %{name: "Rook", discord_user_id: "999"})

    {:ok, character} =
      Characters.set_flag(c.campaign, "456", character.id, "ready", %{
        "type" => "boolean",
        "value" => true,
        "player_visible" => false
      })

    {:ok, old, _} = live(c.conn, ~p"/characters?character_id=#{character.id}")
    {:ok, fresh, _} = live(c.conn, ~p"/characters?character_id=#{character.id}")
    fresh |> form("#character-form", character: %{name: "Away"}) |> render_submit()
    fresh |> form("#character-form", character: %{name: "Rook"}) |> render_submit()
    old |> form("#character-form", character: %{name: "Stale"}) |> render_submit()
    assert has_element?(old, "#flash-error", "Reopen the character")
    old |> element("#clear-flag-ready") |> render_click()
    assert has_element?(old, "#flash-error", "Reopen the character")
    old |> form("#flag-form", flag: %{key: "ready", value: "false"}) |> render_submit()
    assert has_element?(old, "#flash-error", "Reopen the character")
    assert Repo.get!(Character, character.id).name == "Rook"
    assert Repo.get!(Character, character.id).flags["ready"]["value"] == true
  end

  test "connected journey exposes pinned state and DM audit and navigates both ways", c do
    import AsyncWorlds.QuestFixtures
    alias AsyncWorlds.Quests

    {:ok, character} =
      Characters.create_character(c.campaign, "456", %{name: "Rook", discord_user_id: "999"})

    {:ok, revision} =
      Quests.create_quest(
        c.campaign,
        "456",
        %{name: "Crossing", content_id: "crossing"},
        definition()
      )

    {:ok, _} =
      Quests.assign(c.campaign, "456", character.id, revision.id,
        reason: "Secret operating reason"
      )

    {:ok, _} = Quests.append_revision(c.campaign, "456", revision.quest_id, definition())
    {:ok, view, _} = live(c.conn, ~p"/characters?character_id=#{character.id}")
    assert has_element?(view, "#connected-identity", "Discord 999")
    assert has_element?(view, "#connected-position", "pinned revision 1")
    assert has_element?(view, "#connected-position", "hub · active")
    assert has_element?(view, "#character-interventions", "Secret operating reason")
    assert has_element?(view, "#connected-quest-content[href='/quests/library']")
    result = view |> element("#connected-quest-operations") |> render_click()
    {:ok, quest_view, _} = follow_redirect(result, c.conn)

    assert has_element?(
             quest_view,
             "#quest-character-profile[href='/characters?character_id=#{character.id}']"
           )

    result = quest_view |> element("#quest-character-profile") |> render_click()
    {:ok, profile, _} = follow_redirect(result, c.conn)
    assert has_element?(profile, "#connected-identity", "Discord 999")
    assert {:ok, %{name: "Rook", flags: %{}}} = Characters.player_character("123", "999")
  end

  test "expired sessions cannot dispatch character changes", c do
    {:ok, view, _} = live(c.conn, ~p"/characters")
    Repo.update_all(AsyncWorlds.WebAuth.Session, set: [expires_at: ~U[2000-01-01 00:00:00Z]])
    render_submit(view, "save", %{"character" => %{"name" => "Not saved"}})
    assert_redirect(view, ~p"/login")
    assert {:ok, []} = Characters.list_characters(c.campaign, "456")
  end

  test "unauthenticated and revoked sessions cannot access management", c do
    assert {:error, {:redirect, %{to: "/login"}}} = live(build_conn(), ~p"/characters")
    {:ok, view, _} = live(c.conn, ~p"/characters")
    token = get_session(get(c.conn, ~p"/dashboard"), :web_session_token)
    :ok = WebAuth.revoke_session(token)
    assert_redirect(view, ~p"/login")
  end

  test "an open editor loses write authorization when DM configuration changes", c do
    {:ok, character} =
      Characters.create_character(c.campaign, "456", %{name: "Rook", discord_user_id: "999"})

    {:ok, view, _} = live(c.conn, ~p"/characters")
    view |> element("#edit-character-#{character.id}") |> render_click()

    {:ok, _} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "123",
        dm_user_id: "555",
        public_channel_id: "789"
      })

    view |> form("#character-form", character: %{name: "Not saved"}) |> render_submit()
    assert_redirect(view, ~p"/login")
    assert Repo.get!(Character, character.id) == character
  end
end
