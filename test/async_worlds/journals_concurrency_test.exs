defmodule AsyncWorlds.JournalsConcurrencyTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  alias AsyncWorlds.{Campaigns, Characters, Journals, PlayerAccess, Repo}
  alias AsyncWorlds.Campaigns.Campaign
  alias AsyncWorlds.Journals.{CreationReceipt, Entry}
  alias AsyncWorlds.Discord.{DebugSessions, ModalDeadline}
  alias Ecto.Adapters.SQL.Sandbox

  defp db(fun), do: Sandbox.unboxed_run(Repo, fun)

  setup do
    campaign =
      db(fn ->
        {:ok, campaign} =
          Campaigns.setup_campaign(%{
            discord_guild_id: to_string(System.unique_integer([:positive]) + 900_000_000),
            dm_user_id: "456",
            public_channel_id: "789"
          })

        {:ok, _} =
          Characters.create_character(campaign, "456", %{name: "Player", discord_user_id: "991"})

        campaign
      end)

    on_exit(fn ->
      db(fn ->
        Repo.transaction(fn ->
          Repo.delete_all(from e in Entry, where: e.campaign_id == ^campaign.id)
          Repo.delete_all(from r in CreationReceipt, where: r.campaign_id == ^campaign.id)

          Repo.delete_all(
            from s in AsyncWorlds.Discord.DebugSession, where: s.campaign_id == ^campaign.id
          )

          Repo.delete_all(
            from c in AsyncWorlds.Characters.Character, where: c.campaign_id == ^campaign.id
          )

          Repo.delete!(Repo.get!(Campaign, campaign.id))
        end)
      end)
    end)

    supervisor = start_supervised!(Task.Supervisor)

    context =
      db(fn ->
        {:ok, context} = PlayerAccess.context(campaign, "991")
        context
      end)

    %{campaign: campaign, context: context, supervisor: supervisor}
  end

  defp race(supervisor, functions) do
    parent = self()

    tasks =
      Enum.map(functions, fn fun ->
        Task.Supervisor.async_nolink(supervisor, fn ->
          db(fn ->
            send(parent, {:ready, self()})

            receive do
              :go -> fun.()
            end
          end)
        end)
      end)

    for task <- tasks do
      pid = task.pid
      assert_receive {:ready, ^pid}, 5000
    end

    Enum.each(tasks, &send(&1.pid, :go))
    Enum.map(tasks, &Task.await(&1, 10_000))
  end

  defp flow(context), do: Journals.begin_creation(context, System.unique_integer([:positive]))

  test "duplicate initiation and concurrent submissions serialize to one durable entry", c do
    request = System.unique_integer([:positive])

    [{:ok, first}, {:ok, same}] =
      race(c.supervisor, [
        fn -> Journals.begin_creation(c.context, request) end,
        fn -> Journals.begin_creation(c.context, request) end
      ])

    assert first == same

    [{:ok, result}, {:ok, duplicate}] =
      race(c.supervisor, [
        fn -> Journals.submit(c.context, first.id, %{title: "First", body: "A"}) end,
        fn -> Journals.submit(c.context, first.id, %{title: "Second", body: "B"}) end
      ])

    assert result == duplicate

    assert db(fn ->
             Repo.aggregate(from(e in Entry, where: e.campaign_id == ^c.campaign.id), :count)
           end) == 1

    # A fresh process/context retrieves the persisted receipt, not process-local state.
    [{:ok, persisted}] =
      race(c.supervisor, [
        fn ->
          {:ok, context} = PlayerAccess.context(c.campaign, "991")
          Journals.submit(context, first.id, %{title: "Restart", body: "Ignored"})
        end
      ])

    assert persisted == result
  end

  test "concurrent confirmations are idempotent and completed create replay after deletion stays deleted",
       c do
    {receipt, result, target} =
      db(fn ->
        {:ok, receipt} = flow(c.context)
        {:ok, result} = Journals.submit(c.context, receipt.id, %{title: "Title", body: "Body"})
        {:ok, target} = Journals.prepare_delete(c.context, result.entry_id)
        {receipt, result, target}
      end)

    results =
      race(c.supervisor, [
        fn -> Journals.delete_entry(c.context, result.entry_id, target.binding) end,
        fn -> Journals.delete_entry(c.context, result.entry_id, target.binding) end
      ])

    assert Enum.sort(results) == Enum.sort([{:ok, :deleted}, {:ok, :already_deleted}])

    assert {:ok, %{state: :deleted}} =
             db(fn ->
               Journals.submit(c.context, receipt.id, %{title: "Resurrect", body: "No"})
             end)

    assert db(fn -> Repo.get(Entry, result.entry_id) end) == nil
  end

  test "submit racing relink either commits for the original subject or rejects, never retargets",
       c do
    {flow, character} =
      db(fn ->
        {:ok, receipt} = flow(c.context)
        {:ok, chars} = Characters.list_characters(c.campaign, "456")
        {receipt, hd(chars)}
      end)

    [submitted, {:ok, _}] =
      race(c.supervisor, [
        fn -> Journals.submit(c.context, flow.id, %{title: "Title", body: "Body"}) end,
        fn ->
          Characters.update_character(c.campaign, "456", character.id, %{discord_user_id: "992"})
        end
      ])

    assert match?({:ok, _}, submitted) or submitted == {:error, :not_found}
    entries = db(fn -> Repo.all(from e in Entry, where: e.campaign_id == ^c.campaign.id) end)

    assert Enum.all?(
             entries,
             &(&1.character_id == character.id and &1.author_discord_user_id == "991")
           )

    assert length(entries) == if(match?({:ok, _}, submitted), do: 1, else: 0)
  end

  test "persona switch racing creation cannot retarget the form", c do
    {persona, receipt, original, other} =
      db(fn ->
        {:ok, chars} = Characters.list_characters(c.campaign, "456")
        original = hd(chars)
        {:ok, other} = Characters.create_character(c.campaign, "456", %{name: "Other"})

        {:ok, _} =
          DebugSessions.transition(c.campaign.discord_guild_id, "456", {:player, original.id})

        {:ok, persona} = PlayerAccess.context(c.campaign, "456")
        {:ok, receipt} = flow(persona)
        {persona, receipt, original, other}
      end)

    [result, {:ok, _}] =
      race(c.supervisor, [
        fn -> Journals.submit(persona, receipt.id, %{title: "Title", body: "Body"}) end,
        fn ->
          DebugSessions.transition(c.campaign.discord_guild_id, "456", {:player, other.id})
        end
      ])

    assert match?({:ok, _}, result) or result == {:error, :stale_component}
    entries = db(fn -> Repo.all(from e in Entry, where: e.campaign_id == ^c.campaign.id) end)

    assert Enum.all?(
             entries,
             &(&1.character_id == original.id and &1.origin == :dm_persona and
                 &1.author_discord_user_id == "456")
           )
  end

  test "pre-modal preparation cancels real database lock contention within its deadline", c do
    {:ok, receipt} = db(fn -> flow(c.context) end)
    parent = self()

    holder =
      Task.Supervisor.async_nolink(c.supervisor, fn ->
        db(fn ->
          Repo.transaction(fn ->
            Repo.one!(
              from campaign in Campaign, where: campaign.id == ^c.campaign.id, lock: "FOR UPDATE"
            )

            send(parent, :locked)

            receive do
              :release -> :ok
            end
          end)
        end)
      end)

    assert_receive :locked, 5000
    started = System.monotonic_time(:millisecond)

    assert {:error, :modal_deadline} =
             ModalDeadline.run(started + 150, fn ->
               db(fn -> Journals.open_creation(c.context, receipt.id) end)
             end)

    assert System.monotonic_time(:millisecond) - started < 1000
    send(holder.pid, :release)
    assert {:ok, :ok} = Task.await(holder, 5000)
    assert db(fn -> Repo.get!(CreationReceipt, receipt.id).state end) == :pending
    assert {:ok, _} = db(fn -> Journals.open_creation(c.context, receipt.id) end)
  end
end
