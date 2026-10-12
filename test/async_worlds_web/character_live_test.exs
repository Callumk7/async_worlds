defmodule AsyncWorldsWeb.CharacterLiveTest do
  use AsyncWorldsWeb.ConnCase
  import Phoenix.LiveViewTest
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

    view
    |> form("#flag-form",
      flag: %{key: "debt", type: "integer", value: "3", player_visible: "true"}
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

  test "NUL profile and JSON flag input is rejected without crashing the editor", c do
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

    view
    |> form("#flag-form",
      flag: %{key: "nul", type: "string", value: ~s("\\u0000"), player_visible: "true"}
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
