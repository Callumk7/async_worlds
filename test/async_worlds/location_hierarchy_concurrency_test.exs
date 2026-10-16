defmodule AsyncWorlds.LocationHierarchyConcurrencyTest do
  use ExUnit.Case, async: false
  alias AsyncWorlds.{Campaigns, DMAccess, LinkHistory, Locations, Repo}
  alias AsyncWorlds.Campaigns.Campaign
  alias AsyncWorlds.Locations.Location
  alias Ecto.Adapters.SQL.Sandbox

  test "opposing reparent operations serialize and cannot create a cycle" do
    scope =
      db(fn ->
        {:ok, campaign} =
          Campaigns.setup_campaign(%{
            discord_guild_id: to_string(800_000_000 + System.unique_integer([:positive])),
            dm_user_id: "456",
            public_channel_id: "789"
          })

        %{campaign: campaign, discord_user_id: "456"}
      end)

    on_exit(fn -> db(fn -> Repo.delete!(Repo.get!(Campaign, scope.campaign.id)) end) end)

    {a, b} =
      db(fn ->
        {:ok, a} = Locations.create_location(scope, %{name: "A"})
        {:ok, b} = Locations.create_location(scope, %{name: "B"})
        {a, b}
      end)

    supervisor = start_supervised!(Task.Supervisor)
    parent = self()

    first =
      Task.Supervisor.async_nolink(supervisor, fn ->
        db(fn ->
          DMAccess.run(scope, fn _, _ ->
            {:ok, updated} = Locations.set_parent(scope, a.id, b.id)
            send(parent, :first_locked)

            receive do
              :commit -> {:ok, updated}
            end
          end)
        end)
      end)

    assert_receive :first_locked, 5000

    second =
      Task.Supervisor.async_nolink(supervisor, fn ->
        db(fn ->
          %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
          send(parent, {:second_backend, backend})
          Locations.set_parent(scope, b.id, a.id)
        end)
      end)

    assert_receive {:second_backend, backend}, 5000
    assert_blocked(backend, System.monotonic_time(:millisecond) + 5000)
    send(first.pid, :commit)
    assert {:ok, _} = Task.await(first, 10_000)
    assert {:error, :location_cycle} = Task.await(second, 10_000)

    db(fn ->
      assert Repo.get!(Location, a.id).parent_id == b.id
      assert Repo.get!(Location, b.id).parent_id == nil
      assert {:ok, %{items: [_]}} = LinkHistory.list_changes(scope)
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
             "parent writer did not wait for the campaign lock"

      assert_blocked(backend, deadline)
    end
  end
end
