defmodule AsyncWorlds.CampaignsTest do
  use AsyncWorlds.DataCase, async: true

  alias AsyncWorlds.Campaigns
  alias AsyncWorlds.Campaigns.Campaign

  @attrs %{discord_guild_id: "123", dm_user_id: "456", public_channel_id: "789"}

  test "setup persists IDs without signed integer or floating-point truncation" do
    max = "18446744073709551615"
    assert {:ok, campaign} = Campaigns.setup_campaign(%{@attrs | discord_guild_id: max})
    assert campaign.current_tick_number == 0
    assert {:ok, loaded} = Campaigns.fetch_campaign_by_guild(18_446_744_073_709_551_615)
    assert loaded.id == campaign.id
    assert loaded.discord_guild_id == max
  end

  test "repeated setup updates configuration and preserves tick and identity" do
    assert {:ok, first} = Campaigns.setup_campaign(@attrs)
    first |> change(current_tick_number: 7) |> Repo.update!()

    assert {:ok, repeated} = Campaigns.setup_campaign(@attrs)
    assert repeated.id == first.id
    assert repeated.current_tick_number == 7

    assert {:ok, updated} =
             Campaigns.setup_campaign(%{@attrs | dm_user_id: 999, public_channel_id: 888})

    assert updated.id == first.id
    assert updated.inserted_at == first.inserted_at
    assert updated.dm_user_id == "999"
    assert updated.public_channel_id == "888"
    assert updated.current_tick_number == 7
    assert Repo.aggregate(Campaign, :count) == 1
    assert {:error, :unauthorized} = Campaigns.authorize_dm("123", "456")
    assert {:ok, ^updated} = Campaigns.authorize_dm("123", "999")
  end

  test "concurrent setup requests return the same campaign" do
    supervisor = start_supervised!({Task.Supervisor, name: __MODULE__.SetupTasks})
    parent = self()

    tasks =
      for _ <- 1..4 do
        task =
          Task.Supervisor.async_nolink(supervisor, fn ->
            receive do
              :configure -> Campaigns.setup_campaign(@attrs)
            end
          end)

        Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, task.pid)
        task
      end

    Enum.each(tasks, &send(&1.pid, :configure))
    results = Enum.map(tasks, &Task.await/1)
    assert Enum.all?(results, &match?({:ok, %Campaign{}}, &1))
    ids = Enum.map(results, fn {:ok, campaign} -> campaign.id end)
    assert length(Enum.uniq(ids)) == 1
    assert Repo.aggregate(Campaign, :count) == 1
  end

  test "setup cannot set or reset tick progression" do
    assert {:ok, campaign} = Campaigns.setup_campaign(Map.put(@attrs, :current_tick_number, 20))
    assert campaign.current_tick_number == 0
  end

  test "every ID is required and invalid setup does not overwrite existing configuration" do
    {:ok, campaign} = Campaigns.setup_campaign(@attrs)

    for field <- Map.keys(@attrs) do
      assert {:error, missing} = Campaigns.setup_campaign(Map.delete(@attrs, field))
      assert "can't be blank" in Map.fetch!(errors_on(missing), field)

      for invalid <- [
            "0",
            "-1",
            "01",
            " 123",
            "123\n",
            "1.2",
            "abc",
            "18446744073709551616",
            1.0,
            -1,
            %{}
          ] do
        assert {:error, changeset} = Campaigns.setup_campaign(Map.put(@attrs, field, invalid))
        assert Map.has_key?(errors_on(changeset), field)
      end
    end

    assert Repo.get!(Campaign, campaign.id) == campaign
  end

  test "lookups and authorization remain guild scoped and fail closed" do
    {:ok, first} = Campaigns.setup_campaign(@attrs)

    {:ok, second} =
      Campaigns.setup_campaign(%{@attrs | discord_guild_id: "321", dm_user_id: "654"})

    assert {:ok, ^first} = Campaigns.fetch_campaign_by_guild(123)
    assert {:ok, ^second} = Campaigns.fetch_campaign_by_guild("321")
    assert {:error, :not_found} = Campaigns.fetch_campaign_by_guild("111")
    assert {:error, :invalid_id} = Campaigns.fetch_campaign_by_guild(nil)
    assert {:ok, ^first} = Campaigns.authorize_dm(123, 456)
    assert {:error, :unauthorized} = Campaigns.authorize_dm("321", "456")
    assert {:error, :not_found} = Campaigns.authorize_dm("111", "456")
    assert {:error, :invalid_id} = Campaigns.authorize_dm("bad", "456")

    for invalid <- [nil, "bad", "0456", 456.0, "654"] do
      refute Campaigns.dm?(first, invalid)
      assert {:error, :unauthorized} = Campaigns.authorize_dm("123", invalid)
    end

    refute Campaigns.dm?(nil, "456")
    refute Campaigns.dm?(%Campaign{}, nil)
    assert Campaigns.dm?(first, 456)
  end

  test "database enforces unique guilds independently of setup upsert" do
    Campaigns.setup_campaign(@attrs)
    assert {:error, changeset} = %Campaign{} |> Campaign.setup_changeset(@attrs) |> Repo.insert()
    assert "has already been taken" in errors_on(changeset).discord_guild_id
  end

  test "database rejects invalid IDs and negative ticks even without changeset validation" do
    for attrs <- [
          Map.put(@attrs, :current_tick_number, -1),
          Map.put(@attrs, :discord_guild_id, "0"),
          Map.put(@attrs, :dm_user_id, "18446744073709551616")
        ] do
      assert_raise Postgrex.Error, fn ->
        Repo.insert_all(
          "campaigns",
          [Map.merge(attrs, %{inserted_at: DateTime.utc_now(), updated_at: DateTime.utc_now()})],
          mode: :savepoint
        )
      end
    end
  end
end
