defmodule AsyncWorlds.CharactersTest do
  use AsyncWorlds.DataCase, async: true
  alias AsyncWorlds.{Campaigns, Characters, Repo}
  alias AsyncWorlds.Characters.Character

  setup do
    {:ok, campaign} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "123",
        dm_user_id: "456",
        public_channel_id: "789"
      })

    {:ok, other} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "124",
        dm_user_id: "457",
        public_channel_id: "790"
      })

    %{campaign: campaign, other: other}
  end

  defp create(campaign, user \\ "999", attrs \\ %{}) do
    Characters.create_character(
      campaign,
      campaign.dm_user_id,
      Map.merge(%{name: "Rook", discord_user_id: user}, attrs)
    )
  end

  defp flag(type, value, visible),
    do: %{"type" => type, "value" => value, "player_visible" => visible}

  test "campaign ownership is programmatic; player lookup uses identity, never a character ID",
       c do
    {:ok, character} = create(c.campaign, "999", %{campaign_id: c.other.id})
    assert character.campaign_id == c.campaign.id
    {:ok, _} = create(c.other, "999", %{name: "Other Rook"})
    {:ok, _} = create(c.campaign, "998", %{name: "Someone else"})
    assert {:ok, %{name: "Rook", flags: %{}}} = Characters.player_character("123", 999)
    assert {:ok, %{name: "Other Rook", flags: %{}}} = Characters.player_character("124", "999")
    assert {:error, :not_found} = Characters.player_character("123", "997")
    assert {:ok, ^character} = Characters.get_character(c.campaign, "456", character.id)

    {:ok, updated} =
      Characters.update_character(c.campaign, "456", character.id, %{
        name: "Renamed",
        campaign_id: c.other.id
      })

    assert updated.campaign_id == c.campaign.id
    assert updated.name == "Renamed"
  end

  test "invalid snowflakes fail closed for creation, updates, players and DMs", c do
    {:ok, character} = create(c.campaign)

    for id <- [
          nil,
          "",
          "0",
          0,
          -1,
          1.0,
          " 999",
          "+999",
          "0999",
          "999x",
          "18446744073709551616",
          %{}
        ] do
      assert {:error, %Ecto.Changeset{}} = create(c.campaign, id)

      assert {:error, %Ecto.Changeset{}} =
               Characters.update_character(c.campaign, "456", character.id, %{
                 name: "Not saved",
                 discord_user_id: id
               })

      assert {:error, :invalid_id} = Characters.player_character("123", id)

      assert {:error, :invalid_id} =
               Characters.create_character(c.campaign, id, %{name: "No", discord_user_id: "997"})

      assert {:error, :invalid_id} = Characters.get_character(c.campaign, id, character.id)
    end

    assert Repo.get!(Character, character.id) == character
    assert {:error, :invalid_id} = Characters.player_character("0123", "999")
    assert {:ok, _} = create(c.campaign, "18446744073709551615")
  end

  test "an intentional DM relink immediately changes player lookup, not campaign ownership", c do
    {:ok, character} = create(c.campaign)

    {:ok, relinked} =
      Characters.update_character(c.campaign, "456", character.id, %{discord_user_id: 997})

    assert relinked.campaign_id == c.campaign.id
    assert {:error, :not_found} = Characters.player_character("123", "999")
    assert {:ok, %{name: "Rook", flags: %{}}} = Characters.player_character("123", "997")
  end

  test "invalid create facts insert nothing and malformed stored facts fail closed", c do
    assert {:error, %Ecto.Changeset{}} =
             create(c.campaign, "999", %{
               flags: %{"secret" => %{"type" => "boolean", "value" => true}}
             })

    assert {:ok, []} = Characters.list_characters(c.campaign, "456")
    {:ok, character} = create(c.campaign)
    # Defense in depth for imports/old rows that bypass the domain changeset.
    Repo.update!(
      Ecto.Changeset.change(character,
        flags: %{
          "secret" => flag("string", "classified", false),
          "malformed" => flag("boolean", "classified", true),
          "missing_visibility" => %{"type" => "string", "value" => "classified"}
        }
      )
    )

    assert {:ok, %{name: "Rook", flags: %{}}} = Characters.player_character("123", "999")
  end

  test "database unique index rejects bypassed domain inserts and relinks atomically", c do
    {:ok, character} = create(c.campaign)
    # No domain/precheck involved: a valid raw changeset hits the unique index.
    duplicate =
      Character.changeset(%Character{campaign_id: c.campaign.id}, %{
        name: "Duplicate",
        discord_user_id: "999"
      })

    assert duplicate.valid?
    assert {:error, changeset} = Repo.insert(duplicate)
    assert changeset.errors[:discord_user_id]
    {:ok, second} = create(c.campaign, "998")

    assert {:error, %Ecto.Changeset{}} =
             Characters.update_character(c.campaign, "456", second.id, %{
               name: "Not saved",
               discord_user_id: "999"
             })

    assert Repo.get!(Character, second.id) == second
    assert Repo.get!(Character, character.id) == character
    assert {:ok, _} = create(c.other)
  end

  test "all DM boundaries reject other actors and cross-campaign IDs", c do
    {:ok, character} = create(c.other)

    for id <- [character.id, "garbage", -1, nil] do
      assert {:error, :not_found} = Characters.get_character(c.campaign, "456", id)

      assert {:error, :not_found} =
               Characters.update_character(c.campaign, "456", id, %{name: "No"})

      assert {:error, :not_found} =
               Characters.set_flag(c.campaign, "456", id, "visible", flag("boolean", true, true))

      assert {:error, :not_found} = Characters.clear_flag(c.campaign, "456", id, "visible")
    end

    assert {:error, :unauthorized} =
             Characters.create_character(c.campaign, "999", %{name: "No", discord_user_id: "888"})

    assert {:error, :unauthorized} = Characters.list_characters(c.campaign, "999")
    assert {:error, :unauthorized} = Characters.get_character(c.other, "456", character.id)

    assert {:error, :unauthorized} =
             Characters.update_character(c.other, "456", character.id, %{name: "No"})

    assert {:error, :unauthorized} =
             Characters.set_flag(
               c.other,
               "456",
               character.id,
               "visible",
               flag("boolean", true, true)
             )

    assert {:error, :unauthorized} =
             Characters.clear_flag(c.other, "456", character.id, "visible")

    assert Repo.get!(Character, character.id) == character
  end

  test "cached DM configuration never authorizes after reconfiguration", c do
    {:ok, character} = create(c.campaign)

    {:ok, current} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "123",
        dm_user_id: "555",
        public_channel_id: "789"
      })

    assert {:error, :unauthorized} =
             Characters.update_character(c.campaign, "456", character.id, %{name: "No"})

    assert {:error, :unauthorized} = Characters.list_characters(c.campaign, "456")

    assert {:error, :stale_campaign} =
             Characters.update_character(c.campaign, "555", character.id, %{name: "No"})

    assert {:ok, ^character} = Characters.get_character(current, "555", character.id)

    {:ok, _} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "123",
        dm_user_id: "555",
        public_channel_id: "791"
      })

    assert {:error, :stale_campaign} =
             Characters.set_flag(
               current,
               "555",
               character.id,
               "secret",
               flag("boolean", true, false)
             )

    assert Repo.get!(Character, character.id) == character
  end

  test "PostgreSQL-incompatible character names are validation errors", c do
    {:ok, character} = create(c.campaign)

    for name <- ["bad\u0000name", <<255>>, "a" <> String.duplicate("\u0301", 300)] do
      changeset = Character.changeset(character, %{name: name})
      refute changeset.valid?
      assert changeset.errors[:name]

      assert {:error, %Ecto.Changeset{}} =
               Characters.update_character(c.campaign, "456", character.id, %{name: name})

      assert {:error, %Ecto.Changeset{}} = create(c.campaign, "997", %{name: name})
    end

    assert Repo.get!(Character, character.id) == character
  end

  test "NUL string flags are rejected before PostgreSQL persistence", c do
    {:ok, character} = create(c.campaign)
    invalid = flag("string", "before\u0000after", true)
    refute AsyncWorlds.Characters.Flags.valid_flag?(invalid)

    assert {:error, :invalid_flag} =
             Characters.set_flag(c.campaign, "456", character.id, "nul", invalid)

    assert {:error, %Ecto.Changeset{}} =
             Characters.update_character(c.campaign, "456", character.id, %{
               name: "Not saved",
               flags: %{"nul" => invalid}
             })

    assert {:error, %Ecto.Changeset{}} = create(c.campaign, "997", %{flags: %{"nul" => invalid}})
    assert Repo.get!(Character, character.id) == character
    assert {:ok, [^character]} = Characters.list_characters(c.campaign, "456")
  end

  test "strict native types, explicit visibility, whitelist projection and whole-update atomicity",
       c do
    flags = %{
      "secret" => flag("string", "classified", false),
      "alive" => flag("boolean", false, true),
      "debt" => flag("integer", -2, true),
      "title" => flag("string", "Captain", true)
    }

    {:ok, character} = create(c.campaign, "999", %{flags: flags})

    assert {:ok, %{name: "Rook", flags: visible} = payload} =
             Characters.player_character("123", "999")

    assert Map.keys(payload) |> Enum.sort() == [:flags, :name]

    assert visible == %{
             "alive" => %{"type" => "boolean", "value" => false},
             "debt" => %{"type" => "integer", "value" => -2},
             "title" => %{"type" => "string", "value" => "Captain"}
           }

    refute Jason.encode!(payload) =~ "secret"
    refute Jason.encode!(payload) =~ "classified"

    invalid = [
      flag("boolean", "true", true),
      flag("integer", 1.0, true),
      flag("integer", 9_007_199_254_740_992, true),
      flag("string", 1, true),
      flag("object", %{}, false),
      flag("string", nil, true),
      flag("string", "ok", "false"),
      %{"type" => "boolean", "value" => true},
      Map.put(flag("boolean", true, false), "extra", 1)
    ]

    for value <- invalid do
      assert {:error, :invalid_flag} =
               Characters.set_flag(c.campaign, "456", character.id, "invalid", value)

      assert {:error, %Ecto.Changeset{}} =
               Characters.update_character(c.campaign, "456", character.id, %{
                 name: "Not saved",
                 flags: Map.put(flags, "invalid", value)
               })

      assert Repo.get!(Character, character.id) == character
    end

    for flags <- [nil, [], %{"Bad Key" => flag("boolean", true, false)}] do
      assert {:error, %Ecto.Changeset{}} =
               Characters.update_character(c.campaign, "456", character.id, %{flags: flags})
    end

    assert {:error, :invalid_flag} =
             Characters.clear_flag(c.campaign, "456", character.id, "Bad Key")

    {:ok, _} =
      Characters.set_flag(
        c.campaign,
        "456",
        character.id,
        "secret",
        flag("string", "revealed", true)
      )

    assert {:ok, %{flags: %{"secret" => %{"value" => "revealed"}}}} =
             Characters.player_character("123", "999")

    {:ok, _} =
      Characters.set_flag(
        c.campaign,
        "456",
        character.id,
        "secret",
        flag("string", "hidden again", false)
      )

    {:ok, hidden} = Characters.player_character("123", "999")
    refute Map.has_key?(hidden.flags, "secret")
    {:ok, updated} = Characters.clear_flag(c.campaign, "456", character.id, "alive")
    refute Map.has_key?(updated.flags, "alive")
    assert {:ok, ^updated} = Characters.clear_flag(c.campaign, "456", character.id, "alive")
  end
end
