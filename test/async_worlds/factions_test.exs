defmodule AsyncWorlds.FactionsTest do
  use AsyncWorlds.DataCase, async: true

  alias AsyncWorlds.{Campaigns, Factions, Repo}
  alias AsyncWorlds.Factions.Faction

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

    %{
      scope: %{campaign: campaign, discord_user_id: campaign.dm_user_id},
      other: %{campaign: other, discord_user_id: other.dm_user_id}
    }
  end

  test "CRUD round trip with optional description and string IDs", %{scope: scope} do
    assert {:ok, []} = Factions.list_factions(scope)
    assert {:ok, faction} = Factions.create_faction(scope, %{name: "The Guild"})
    assert faction.description == nil
    assert faction.campaign_id == scope.campaign.id
    assert {:ok, ^faction} = Factions.get_faction(scope, to_string(faction.id))
    assert {:ok, [^faction]} = Factions.list_factions(scope)

    assert {:ok, updated} =
             Factions.update_faction(scope, faction.id, %{
               "name" => "The Merchants",
               "description" => "A trading alliance."
             })

    assert updated.name == "The Merchants"
    assert updated.description == "A trading alliance."
    assert {:ok, cleared} = Factions.update_faction(scope, faction.id, %{description: nil})
    assert cleared.description == nil
    assert {:ok, deleted} = Factions.delete_faction(scope, faction.id)
    assert deleted.id == cleared.id
    refute Repo.get(Faction, faction.id)
    assert {:error, :not_found} = Factions.get_faction(scope, faction.id)
    assert {:ok, []} = Factions.list_factions(scope)
  end

  test "lists only campaign-owned factions in stable order", %{scope: scope, other: other} do
    {:ok, first} = Factions.create_faction(scope, %{name: "First"})
    {:ok, second} = Factions.create_faction(scope, %{name: "Second"})
    {:ok, _} = Factions.create_faction(other, %{name: "Other"})
    assert {:ok, [^first, ^second]} = Factions.list_factions(scope)
  end

  test "campaign ownership cannot be reassigned and foreign targets are hidden", c do
    {:ok, faction} =
      Factions.create_faction(c.scope, %{name: "Guild", campaign_id: c.other.campaign.id})

    assert faction.campaign_id == c.scope.campaign.id

    assert {:ok, updated} =
             Factions.update_faction(c.scope, faction.id, %{campaign_id: c.other.campaign.id})

    assert updated.campaign_id == c.scope.campaign.id
    assert {:error, :not_found} = Factions.get_faction(c.other, faction.id)
    assert {:error, :not_found} = Factions.update_faction(c.other, faction.id, %{name: "No"})
    assert {:error, :not_found} = Factions.delete_faction(c.other, faction.id)
    assert {:error, :not_found} = Factions.change_faction(c.other, faction.id)
    assert Repo.get!(Faction, faction.id).name == "Guild"
  end

  test "invalid changes return changesets without persisting", %{scope: scope} do
    for name <- [nil, "", "   ", String.duplicate("a", 201), "bad" <> <<0>>] do
      assert {:error, %Ecto.Changeset{}} = Factions.create_faction(scope, %{name: name})
    end

    assert {:ok, []} = Factions.list_factions(scope)
    {:ok, faction} = Factions.create_faction(scope, %{name: "Valid"})

    assert {:error, %Ecto.Changeset{}} =
             Factions.update_faction(scope, faction.id, %{name: ""})

    assert {:error, %Ecto.Changeset{}} =
             Factions.update_faction(scope, faction.id, %{description: "bad" <> <<0>>})

    assert {:ok, ^faction} = Factions.get_faction(scope, faction.id)
  end

  test "authorized form changesets do not persist", %{scope: scope} do
    assert {:ok, %Ecto.Changeset{} = new} = Factions.change_faction(scope)
    assert new.data.campaign_id == scope.campaign.id
    assert {:ok, []} = Factions.list_factions(scope)
    {:ok, faction} = Factions.create_faction(scope, %{name: "Guild"})
    assert {:ok, changeset} = Factions.change_faction(scope, faction.id, %{name: "Preview"})
    assert Ecto.Changeset.get_change(changeset, :name) == "Preview"
    assert {:ok, ^faction} = Factions.get_faction(scope, faction.id)
  end

  test "all operations require fresh DM authorization", %{scope: scope} do
    {:ok, faction} = Factions.create_faction(scope, %{name: "Guild"})
    denied = %{scope | discord_user_id: "999"}

    for operation <- [
          fn s -> Factions.list_factions(s) end,
          fn s -> Factions.get_faction(s, faction.id) end,
          fn s -> Factions.create_faction(s, %{name: "No"}) end,
          fn s -> Factions.update_faction(s, faction.id, %{name: "No"}) end,
          fn s -> Factions.delete_faction(s, faction.id) end,
          fn s -> Factions.change_faction(s, faction.id) end
        ] do
      assert {:error, :unauthorized} = operation.(denied)
      assert {:error, :invalid_scope} = operation.(%{})
      assert {:error, :invalid_id} = operation.(%{scope | discord_user_id: "invalid"})
    end

    Repo.update!(Ecto.Changeset.change(scope.campaign, public_channel_id: "791"))
    assert {:error, :stale_campaign} = Factions.delete_faction(scope, faction.id)
    assert Repo.get!(Faction, faction.id) == faction
  end

  test "missing and malformed IDs return not found", %{scope: scope} do
    for id <- [nil, -1, 0, "bad", %{}, 9_223_372_036_854_775_808, "999999"] do
      assert {:error, :not_found} = Factions.get_faction(scope, id)
      assert {:error, :not_found} = Factions.update_faction(scope, id, %{name: "No"})
      assert {:error, :not_found} = Factions.delete_faction(scope, id)
    end
  end

  test "database enforces campaign foreign key and cascades deletion", %{scope: scope} do
    changeset = Faction.changeset(%Faction{campaign_id: -1}, %{name: "Orphan"})
    assert {:error, invalid} = Repo.insert(changeset)
    assert errors_on(invalid).campaign_id == ["does not exist"]

    {:ok, faction} = Factions.create_faction(scope, %{name: "Guild"})
    Repo.delete!(scope.campaign)
    refute Repo.get(Faction, faction.id)
    assert {:error, :not_found} = Factions.list_factions(scope)
  end
end
