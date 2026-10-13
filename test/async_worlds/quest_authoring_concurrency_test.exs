defmodule AsyncWorlds.QuestAuthoringConcurrencyTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  import AsyncWorlds.QuestFixtures
  alias AsyncWorlds.{Campaigns, Quests, Repo}
  alias AsyncWorlds.Quests.{Quest, Revision, WorkingCopy}
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    {campaign, revision, work} =
      db(fn ->
        {:ok, campaign} =
          Campaigns.setup_campaign(%{
            discord_guild_id: to_string(900_000_000 + System.unique_integer([:positive])),
            dm_user_id: "456",
            public_channel_id: "789"
          })

        # An effect-free definition is editable through the fixed vocabulary.
        definition = replace_choice(definition(), choice("finish", "end"))

        {:ok, revision} =
          Quests.create_quest(campaign, "456", %{content_id: "race", name: "Race"}, definition)

        {:ok, work} = Quests.create_working_copy(campaign, "456", revision.id)
        {campaign, revision, work}
      end)

    on_exit(fn -> cleanup(campaign.id) end)

    %{
      campaign: campaign,
      revision: revision,
      work: work,
      supervisor: start_supervised!({Task.Supervisor, name: __MODULE__.Tasks})
    }
  end

  defp db(fun), do: Sandbox.unboxed_run(Repo, fun)
  defp attrs(work), do: Map.take(work, [:name, :content_id, :definition])

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

  for action <- [:save, :release] do
    @action action
    test "concurrent #{@action} requests have one winner and no partial writes", c do
      fun = fn name ->
        attrs = Map.put(attrs(c.work), :name, name)

        if @action == :save,
          do: Quests.save_working_copy(c.campaign, "456", c.work.id, c.work.version, attrs),
          else: Quests.release_working_copy(c.campaign, "456", c.work.id, c.work.version, attrs)
      end

      results = race(c.supervisor, [fn -> fun.("First") end, fn -> fun.("Second") end])
      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &(&1 == {:error, :stale_working_copy})) == 1

      db(fn ->
        work = Repo.get!(WorkingCopy, c.work.id)
        assert work.version == 2
        assert work.name in ["First", "Second"]

        count =
          Repo.aggregate(from(r in Revision, where: r.quest_id == ^c.revision.quest_id), :count)

        assert count == if(@action == :release, do: 2, else: 1)
        assert Repo.get!(Revision, c.revision.id) == c.revision
      end)
    end
  end

  test "separate editors releasing the same base serialize to one revision", c do
    {:ok, other} = db(fn -> Quests.create_working_copy(c.campaign, "456", c.revision.id) end)

    results =
      race(
        c.supervisor,
        Enum.map([c.work, other], fn work ->
          fn ->
            Quests.release_working_copy(c.campaign, "456", work.id, work.version, attrs(work))
          end
        end)
      )

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :stale_base_revision})) == 1

    db(fn ->
      assert Repo.aggregate(
               from(r in Revision, where: r.quest_id == ^c.revision.quest_id),
               :count
             ) == 2
    end)
  end

  test "import racing release serializes and never overwrites an immutable base", c do
    imported =
      put_in(c.revision.definition, ["nodes", Access.at(0), "text"], "Imported new narrative")

    json =
      Jason.encode!(%{
        "version" => 1,
        "quests" => [%{"content_id" => "race", "name" => "Import", "definition" => imported}]
      })

    [release_result, {:ok, [%{revision: imported_revision}]}] =
      race(c.supervisor, [
        fn ->
          Quests.release_working_copy(c.campaign, "456", c.work.id, c.work.version, attrs(c.work))
        end,
        fn -> Quests.import_json(c.campaign, "456", json) end
      ])

    assert match?({:ok, _}, release_result) or release_result == {:error, :stale_base_revision}

    db(fn ->
      assert Repo.get!(Revision, c.revision.id) == c.revision

      revisions =
        Repo.all(
          from r in Revision, where: r.quest_id == ^c.revision.quest_id, order_by: r.number
        )

      assert Enum.map(revisions, & &1.number) == Enum.to_list(1..length(revisions))
      assert List.last(revisions) == imported_revision
      assert length(revisions) == if(match?({:ok, _}, release_result), do: 3, else: 2)
      work = Repo.get!(WorkingCopy, c.work.id)
      assert work.version == if(match?({:ok, _}, release_result), do: 2, else: 1)
    end)
  end

  defp cleanup(campaign_id) do
    db(fn ->
      Repo.transaction(fn ->
        Repo.delete_all(from d in WorkingCopy, where: d.campaign_id == ^campaign_id)

        Repo.query!(
          "ALTER TABLE quest_revision_nodes DISABLE TRIGGER immutable_quest_revision_nodes"
        )

        Repo.query!("ALTER TABLE quest_revisions DISABLE TRIGGER immutable_quest_revisions")
        revisions = from r in Revision, where: r.campaign_id == ^campaign_id, select: r.id

        Repo.delete_all(
          from n in "quest_revision_nodes", where: n.revision_id in subquery(revisions)
        )

        Repo.delete_all(from r in Revision, where: r.campaign_id == ^campaign_id)

        Repo.query!(
          "ALTER TABLE quest_revision_nodes ENABLE TRIGGER immutable_quest_revision_nodes"
        )

        Repo.query!("ALTER TABLE quest_revisions ENABLE TRIGGER immutable_quest_revisions")
        Repo.delete_all(from q in Quest, where: q.campaign_id == ^campaign_id)
        Repo.delete!(Repo.get!(AsyncWorlds.Campaigns.Campaign, campaign_id))
      end)
    end)
  end
end
