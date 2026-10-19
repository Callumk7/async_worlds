defmodule AsyncWorlds.TensionCommitmentsConcurrencyTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  alias AsyncWorlds.{Campaigns, Characters, Repo, TensionCommitments, Tensions, Ticks}
  alias AsyncWorlds.Campaigns.Campaign
  alias Ecto.Adapters.SQL.Sandbox

  defp db(fun), do: Sandbox.unboxed_run(Repo, fun)

  setup do
    {campaign, tension, tick, entry} =
      db(fn ->
        {:ok, campaign} =
          Campaigns.setup_campaign(%{
            discord_guild_id: to_string(800_000_000 + System.unique_integer([:positive])),
            dm_user_id: "456",
            public_channel_id: "789"
          })

        {:ok, _} =
          Characters.create_character(campaign, "456", %{name: "Rook", discord_user_id: "999"})

        {:ok, tension} =
          Tensions.create_tension(campaign.id, %{name: "Battle", audience: :public}, "dm")

        {:ok, tick} = Ticks.open_tick(campaign.id)

        {:ok, entry} =
          TensionCommitments.change(
            campaign.discord_guild_id,
            "999",
            tick.id,
            tension.id,
            0,
            :edit,
            %{"intention" => "Original"}
          )

        {campaign, tension, tick, entry}
      end)

    on_exit(fn ->
      db(fn ->
        Repo.delete_all(
          from j in Oban.Job,
            where: fragment("?->>'campaign_id' = ?", j.args, ^to_string(campaign.id))
        )

        discussion_ids =
          Repo.all(
            from d in AsyncWorlds.Tensions.Discussion,
              where: d.campaign_id == ^campaign.id,
              select: d.id
          )
          |> Enum.map(&to_string/1)

        Repo.delete_all(
          from j in Oban.Job,
            where:
              j.worker == "AsyncWorlds.Workers.OpenTensionDiscussion" and
                fragment("?->>'discussion_id'", j.args) in ^discussion_ids
        )

        Repo.delete!(Repo.get!(Campaign, campaign.id))
      end)
    end)

    %{
      c: campaign,
      t: tension,
      tick: tick,
      entry: entry,
      supervisor: start_supervised!(Task.Supervisor)
    }
  end

  defp revision(x),
    do:
      TensionCommitments.change(
        x.c.discord_guild_id,
        "999",
        x.tick.id,
        x.t.id,
        x.entry.version,
        :edit,
        %{"intention" => "Revised"}
      )

  defp close(x), do: Ticks.close_tick(x.c.id, x.tick.id)

  # The first process holds the actual lifecycle lock through the operation and
  # signals its uncommitted result. The competitor uses a separate connection.
  # Releasing the first process commits it before the waiting competitor proceeds.
  defp ordered(x, first, second) do
    parent = self()

    winner =
      Task.Supervisor.async_nolink(x.supervisor, fn ->
        db(fn ->
          {:ok, result} =
            Repo.transaction(fn ->
              Repo.one!(from c in Campaign, where: c.id == ^x.c.id, lock: "FOR UPDATE")
              result = first.()
              send(parent, {:staged, self(), result})

              receive do
                :commit -> result
              end
            end)

          result
        end)
      end)

    pid = winner.pid
    assert_receive {:staged, ^pid, _}, 5000

    competitor =
      Task.Supervisor.async_nolink(x.supervisor, fn ->
        db(fn ->
          send(parent, {:competing, self()})
          second.()
        end)
      end)

    other = competitor.pid
    assert_receive {:competing, ^other}, 5000
    send(pid, :commit)
    {finish(winner), finish(competitor)}
  end

  defp finish(task) do
    ref = task.ref
    pid = task.pid
    assert_receive {^ref, result}, 10000
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 10000
    result
  end

  test "revision obtains lifecycle lock first: exact latest version freezes", x do
    {{:ok, revised}, {:ok, %{snapshot: snapshot}}} =
      ordered(x, fn -> revision(x) end, fn -> close(x) end)

    frozen = hd(hd(snapshot.data["tension_commitments"])["commitments"])
    assert frozen["version"] == revised.version
    assert frozen["intention"] == "Revised"
    assert frozen["state"] == "unresolved"
    assert frozen["ready"] == false
    assert db(fn -> revision(x) end) == {:error, :tick_closed}
    assert {:ok, ^snapshot} = db(fn -> Ticks.fetch_snapshot(x.c.id, x.tick.id) end)
  end

  test "close obtains lifecycle lock first: concurrent revision and all late messages rejected",
       x do
    {{:ok, %{snapshot: snapshot}}, {:error, :tick_closed}} =
      ordered(x, fn -> close(x) end, fn -> revision(x) end)

    frozen = hd(hd(snapshot.data["tension_commitments"])["commitments"])
    assert frozen["version"] == x.entry.version
    assert frozen["intention"] == "Original"

    for operation <- [:edit, :confirm, :ready, :withdraw] do
      assert {:error, :tick_closed} =
               db(fn ->
                 TensionCommitments.change(
                   x.c.discord_guild_id,
                   "999",
                   x.tick.id,
                   x.t.id,
                   x.entry.version,
                   operation,
                   %{"intention" => "late"}
                 )
               end)
    end

    assert {:ok, %{snapshot: ^snapshot}} = db(fn -> close(x) end)
  end

  test "two edits of the same version cannot both succeed", x do
    {{:ok, revised}, {:error, :stale_commitment}} =
      ordered(x, fn -> revision(x) end, fn -> revision(x) end)

    assert revised.version == 2
  end
end
