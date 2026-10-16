defmodule AsyncWorlds.MembershipsConcurrencyTest do
  use ExUnit.Case, async: false

  alias AsyncWorlds.{Campaigns, Characters, DMAccess, Factions, LinkHistory, Memberships, Repo}
  alias AsyncWorlds.Campaigns.Campaign
  alias AsyncWorlds.Factions.Membership
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    context =
      db(fn ->
        {:ok, campaign} =
          Campaigns.setup_campaign(%{
            discord_guild_id: to_string(800_000_000 + System.unique_integer([:positive])),
            dm_user_id: "456",
            public_channel_id: "789"
          })

        scope = %{campaign: campaign, discord_user_id: "456"}
        {:ok, character} = Characters.create_character(campaign, "456", %{name: "Mira"})
        {:ok, faction} = Factions.create_faction(scope, %{name: "Guild"})
        %{scope: scope, character: character, faction: faction}
      end)

    on_exit(fn -> db(fn -> Repo.delete!(Repo.get!(Campaign, context.scope.campaign.id)) end) end)
    Map.put(context, :supervisor, start_supervised!(Task.Supervisor))
  end

  test "concurrent duplicate joins serialize and create one current membership and one change",
       c do
    parent = self()

    first =
      Task.Supervisor.async_nolink(c.supervisor, fn ->
        db(fn ->
          DMAccess.run(c.scope, fn _, _ ->
            {:ok, membership} =
              Memberships.join(c.scope, c.character.id, c.faction.id, %{role: "Scout"})

            send(parent, :first_locked)

            receive do
              :commit -> {:ok, membership}
            end
          end)
        end)
      end)

    assert_receive :first_locked, 5000
    second = waiting_join(c, parent)
    assert_receive {:joining_backend, backend}, 5000
    assert_blocked(backend, System.monotonic_time(:millisecond) + 5000)
    send(first.pid, :commit)
    assert {:ok, membership} = Task.await(first, 10_000)
    assert {:error, %Ecto.Changeset{} = duplicate} = Task.await(second, 10_000)
    assert duplicate.errors[:character_id]

    db(fn ->
      assert Repo.get!(Membership, membership.id).role == "Scout"
      assert {:ok, [current]} = Memberships.list_faction_members(c.scope, c.faction.id)
      assert current.id == membership.id
      assert {:ok, %{items: [record]}} = LinkHistory.list_changes(c.scope)
      assert record.link_id == membership.id
    end)
  end

  test "a DM revoked while waiting for the lock cannot create a membership", c do
    parent = self()

    reconfigure =
      Task.Supervisor.async_nolink(c.supervisor, fn ->
        db(fn ->
          Repo.transaction(fn ->
            {:ok, campaign} =
              Campaigns.setup_campaign(%{
                discord_guild_id: c.scope.campaign.discord_guild_id,
                dm_user_id: "457",
                public_channel_id: "789"
              })

            send(parent, :reconfiguration_locked)

            receive do
              :commit -> campaign
            end
          end)
        end)
      end)

    assert_receive :reconfiguration_locked, 5000
    joining = waiting_join(c, parent)
    assert_receive {:joining_backend, backend}, 5000
    assert_blocked(backend, System.monotonic_time(:millisecond) + 5000)
    send(reconfigure.pid, :commit)
    assert {:ok, campaign} = Task.await(reconfigure, 10_000)
    assert {:error, :unauthorized} = Task.await(joining, 10_000)

    db(fn ->
      scope = %{campaign: campaign, discord_user_id: "457"}
      assert {:ok, []} = Memberships.list_faction_members(scope, c.faction.id)
      assert {:ok, %{items: []}} = LinkHistory.list_changes(scope)
    end)
  end

  defp waiting_join(c, parent) do
    Task.Supervisor.async_nolink(c.supervisor, fn ->
      db(fn ->
        %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
        send(parent, {:joining_backend, backend})
        Memberships.join(c.scope, c.character.id, c.faction.id, %{role: "Captain"})
      end)
    end)
  end

  defp db(fun), do: Sandbox.unboxed_run(Repo, fun)

  defp assert_blocked(backend, deadline) do
    blocked =
      db(fn ->
        %{rows: [[blocked]]} =
          Repo.query!("SELECT cardinality(pg_blocking_pids($1)) > 0", [backend])

        blocked
      end)

    unless blocked do
      assert System.monotonic_time(:millisecond) < deadline,
             "membership join did not wait for the campaign lock"

      assert_blocked(backend, deadline)
    end
  end
end
