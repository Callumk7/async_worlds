defmodule AsyncWorlds.DM.AuthorizationConcurrencyTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  alias AsyncWorlds.{Campaigns, Repo}
  alias AsyncWorlds.Campaigns.Campaign
  alias AsyncWorlds.DM.Ticks
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    campaign =
      db(fn ->
        {:ok, campaign} =
          Campaigns.setup_campaign(%{
            discord_guild_id: to_string(800_000_000 + System.unique_integer([:positive])),
            dm_user_id: "456",
            public_channel_id: "789"
          })

        campaign
      end)

    on_exit(fn ->
      db(fn ->
        Repo.delete_all(
          from j in Oban.Job,
            where: fragment("?->>'campaign_id' = ?", j.args, ^to_string(campaign.id))
        )

        Repo.delete!(Repo.get!(Campaign, campaign.id))
      end)
    end)

    supervisor = start_supervised!({Task.Supervisor, name: __MODULE__.Tasks})
    %{scope: %{campaign: campaign, discord_user_id: "456"}, supervisor: supervisor}
  end

  defp db(fun), do: Sandbox.unboxed_run(Repo, fun)

  test "a DM revoked while waiting for the campaign lock cannot open a tick", %{
    scope: scope,
    supervisor: supervisor
  } do
    parent = self()

    reconfigure =
      Task.Supervisor.async_nolink(supervisor, fn ->
        db(fn ->
          Repo.transaction(fn ->
            {:ok, campaign} =
              Campaigns.setup_campaign(%{
                discord_guild_id: scope.campaign.discord_guild_id,
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

    opening =
      Task.Supervisor.async_nolink(supervisor, fn ->
        db(fn ->
          %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
          send(parent, {:opening_backend, backend})
          Ticks.open_tick(scope)
        end)
      end)

    assert_receive {:opening_backend, backend}, 5000
    # Observe PostgreSQL's lock wait, not a timing-based sleep or shared-sandbox task.
    assert_blocked(backend, System.monotonic_time(:millisecond) + 5000)
    send(reconfigure.pid, :commit)
    assert {:ok, _} = Task.await(reconfigure, 10000)
    assert {:error, :unauthorized} = Task.await(opening, 10000)
    assert db(fn -> AsyncWorlds.Ticks.active_tick(scope.campaign.id) end) == nil
    assert db(fn -> AsyncWorlds.Deliveries.list_deliveries(scope.campaign.id) end) == []
  end

  defp assert_blocked(backend, deadline) do
    blocked =
      db(fn ->
        %{rows: [[blocked]]} =
          Repo.query!("SELECT cardinality(pg_blocking_pids($1)) > 0", [backend])

        blocked
      end)

    unless blocked do
      assert System.monotonic_time(:millisecond) < deadline,
             "operation did not wait for the campaign lock"

      assert_blocked(backend, deadline)
    end
  end
end
