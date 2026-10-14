defmodule AsyncWorlds.LocationsTest do
  use AsyncWorlds.DataCase, async: true

  alias AsyncWorlds.{Campaigns, Locations, Repo}
  alias AsyncWorlds.Locations.Location

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
    assert {:ok, []} = Locations.list_locations(scope)
    assert {:ok, location} = Locations.create_location(scope, %{name: "The Guild"})
    assert location.description == nil
    assert location.campaign_id == scope.campaign.id
    assert {:ok, ^location} = Locations.get_location(scope, to_string(location.id))
    assert {:ok, [^location]} = Locations.list_locations(scope)

    assert {:ok, updated} =
             Locations.update_location(scope, location.id, %{
               "name" => "The Merchants",
               "description" => "A trading alliance."
             })

    assert updated.name == "The Merchants"
    assert updated.description == "A trading alliance."
    assert {:ok, cleared} = Locations.update_location(scope, location.id, %{description: nil})
    assert cleared.description == nil
    assert {:ok, deleted} = Locations.delete_location(scope, location.id)
    assert deleted.id == cleared.id
    refute Repo.get(Location, location.id)
    assert {:error, :not_found} = Locations.get_location(scope, location.id)
    assert {:ok, []} = Locations.list_locations(scope)
  end

  test "lists only campaign-owned locations in stable order", %{scope: scope, other: other} do
    {:ok, first} = Locations.create_location(scope, %{name: "First"})
    {:ok, second} = Locations.create_location(scope, %{name: "Second"})
    {:ok, _} = Locations.create_location(other, %{name: "Other"})
    assert {:ok, [^first, ^second]} = Locations.list_locations(scope)
  end

  test "campaign ownership cannot be reassigned and foreign targets are hidden", c do
    {:ok, location} =
      Locations.create_location(c.scope, %{name: "Guild", campaign_id: c.other.campaign.id})

    assert location.campaign_id == c.scope.campaign.id

    assert {:ok, updated} =
             Locations.update_location(c.scope, location.id, %{campaign_id: c.other.campaign.id})

    assert updated.campaign_id == c.scope.campaign.id
    assert {:error, :not_found} = Locations.get_location(c.other, location.id)
    assert {:error, :not_found} = Locations.update_location(c.other, location.id, %{name: "No"})
    assert {:error, :not_found} = Locations.delete_location(c.other, location.id)
    assert {:error, :not_found} = Locations.change_location(c.other, location.id)
    assert Repo.get!(Location, location.id).name == "Guild"
  end

  test "invalid changes return changesets without persisting", %{scope: scope} do
    for name <- [nil, "", "   ", String.duplicate("a", 201), "bad" <> <<0>>] do
      assert {:error, %Ecto.Changeset{}} = Locations.create_location(scope, %{name: name})
    end

    assert {:ok, []} = Locations.list_locations(scope)
    {:ok, location} = Locations.create_location(scope, %{name: "Valid"})

    assert {:error, %Ecto.Changeset{}} =
             Locations.update_location(scope, location.id, %{name: ""})

    assert {:error, %Ecto.Changeset{}} =
             Locations.update_location(scope, location.id, %{description: "bad" <> <<0>>})

    assert {:ok, ^location} = Locations.get_location(scope, location.id)
  end

  test "authorized form changesets do not persist", %{scope: scope} do
    assert {:ok, %Ecto.Changeset{} = new} = Locations.change_location(scope)
    assert new.data.campaign_id == scope.campaign.id
    assert {:ok, []} = Locations.list_locations(scope)
    {:ok, location} = Locations.create_location(scope, %{name: "Guild"})
    assert {:ok, changeset} = Locations.change_location(scope, location.id, %{name: "Preview"})
    assert Ecto.Changeset.get_change(changeset, :name) == "Preview"
    assert {:ok, ^location} = Locations.get_location(scope, location.id)
  end

  test "all operations require fresh DM authorization", %{scope: scope} do
    {:ok, location} = Locations.create_location(scope, %{name: "Guild"})
    denied = %{scope | discord_user_id: "999"}

    for operation <- [
          fn s -> Locations.list_locations(s) end,
          fn s -> Locations.get_location(s, location.id) end,
          fn s -> Locations.create_location(s, %{name: "No"}) end,
          fn s -> Locations.update_location(s, location.id, %{name: "No"}) end,
          fn s -> Locations.delete_location(s, location.id) end,
          fn s -> Locations.change_location(s, location.id) end
        ] do
      assert {:error, :unauthorized} = operation.(denied)
      assert {:error, :invalid_scope} = operation.(%{})
      assert {:error, :invalid_id} = operation.(%{scope | discord_user_id: "invalid"})
    end

    Repo.update!(Ecto.Changeset.change(scope.campaign, public_channel_id: "791"))
    assert {:error, :stale_campaign} = Locations.delete_location(scope, location.id)
    assert Repo.get!(Location, location.id) == location
  end

  test "missing and malformed IDs return not found", %{scope: scope} do
    for id <- [nil, -1, 0, "bad", %{}, 9_223_372_036_854_775_808, "999999"] do
      assert {:error, :not_found} = Locations.get_location(scope, id)
      assert {:error, :not_found} = Locations.update_location(scope, id, %{name: "No"})
      assert {:error, :not_found} = Locations.delete_location(scope, id)
    end
  end

  test "campaign-readable projections are scoped and exclude ownership metadata", c do
    {:ok, location} = Locations.create_location(c.scope, %{name: "Harbour", description: "Docks"})
    {:ok, foreign} = Locations.create_location(c.other, %{name: "Other harbour"})

    assert {:ok, [%{id: location.id, name: "Harbour"}]} ==
             Locations.list_campaign_locations(c.scope.campaign.discord_guild_id)

    assert {:ok, %{id: location.id, name: "Harbour", description: "Docks"}} ==
             Locations.get_campaign_location(c.scope.campaign.discord_guild_id, location.id)

    assert {:error, :not_found} =
             Locations.get_campaign_location(c.scope.campaign.discord_guild_id, foreign.id)

    assert {:error, :not_found} = Locations.list_campaign_locations("999")
    assert {:error, :not_found} = Locations.get_campaign_location("999", location.id)
  end

  test "database enforces campaign foreign key and cascades deletion", %{scope: scope} do
    changeset = Location.changeset(%Location{campaign_id: -1}, %{name: "Orphan"})
    assert {:error, invalid} = Repo.insert(changeset)
    assert errors_on(invalid).campaign_id == ["does not exist"]

    {:ok, location} = Locations.create_location(scope, %{name: "Guild"})
    Repo.delete!(scope.campaign)
    refute Repo.get(Location, location.id)
    assert {:error, :not_found} = Locations.list_locations(scope)
  end
end
