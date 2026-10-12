defmodule AsyncWorlds.PrivateTickNotificationsTest do
  use AsyncWorlds.DataCase, async: false
  import AsyncWorlds.QuestFixtures
  alias AsyncWorlds.{Campaigns, Characters, Deliveries, Quests, Ticks}
  alias AsyncWorlds.Discord.FakeAdapter
  alias AsyncWorlds.Workers.DeliverDiscord

  setup do
    start_supervised!({FakeAdapter, owner: self()})
    previous = Application.fetch_env!(:async_worlds, :discord)
    Application.put_env(:async_worlds, :discord, enabled: true, adapter: FakeAdapter)
    on_exit(fn -> Application.put_env(:async_worlds, :discord, previous) end)

    {:ok, campaign} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "123",
        dm_user_id: "456",
        public_channel_id: "789"
      })

    {:ok, revision} =
      Quests.create_quest(campaign, "456", %{content_id: "quest", name: "Quest"}, definition())

    for user <- ["991", "992"] do
      {:ok, character} =
        Characters.create_character(campaign, "456", %{name: user, discord_user_id: user})

      {:ok, _} = Quests.assign(campaign, "456", character.id, revision.id)
    end

    %{campaign: campaign}
  end

  test "remind freshly authorizes DM, queues only missing choices and deduplicates request IDs without game writes",
       c do
    {:ok, tick} = Ticks.open_tick(c.campaign.id)
    {:ok, state} = AsyncWorlds.Quests.Submissions.player_state("123", "991")
    {:ok, _} = AsyncWorlds.Quests.Submissions.submit("123", "991", state.identity, "loop")

    assert {:error, :unauthorized} =
             AsyncWorlds.Ticks.PrivateNotifications.remind("123", "991", "100")

    before =
      {Repo.all(AsyncWorlds.Quests.Progression), Repo.all(AsyncWorlds.Quests.Submission),
       Repo.get!(AsyncWorlds.Ticks.Tick, tick.id)}

    assert {:ok, 1} = AsyncWorlds.Ticks.PrivateNotifications.remind("123", "456", "100")
    assert {:ok, 1} = AsyncWorlds.Ticks.PrivateNotifications.remind("123", "456", "100")
    assert {:ok, 1} = AsyncWorlds.Ticks.PrivateNotifications.remind("123", "456", "103")

    reminders =
      Deliveries.list_deliveries(c.campaign.id)
      |> Enum.filter(&String.contains?(&1.key, ":reminder:"))

    assert [%{recipient_id: "992"}] = reminders

    assert before ==
             {Repo.all(AsyncWorlds.Quests.Progression), Repo.all(AsyncWorlds.Quests.Submission),
              Repo.get!(AsyncWorlds.Ticks.Tick, tick.id)}

    assert {:ok, :tick_remind, :dm} =
             AsyncWorlds.Discord.Commands.route(%{
               name: "tick",
               options: [%{name: "remind", type: 1}]
             })
  end

  for stale <- [:submitted, :closed, :moved, :owner_changed, :dm_revoked, :guild_changed] do
    @stale stale
    test "delivery suppresses #{@stale} reminder with fresh state; targeted retry cannot bypass it",
         c do
      {:ok, tick} = Ticks.open_tick(c.campaign.id)
      {:ok, 2} = AsyncWorlds.Ticks.PrivateNotifications.remind("123", "456", "101")

      reminder =
        Enum.find(
          Deliveries.list_deliveries(c.campaign.id),
          &(&1.recipient_id == "991" and String.contains?(&1.key, ":reminder:"))
        )

      {:ok, state} = AsyncWorlds.Quests.Submissions.player_state("123", "991")
      character = Repo.get_by!(AsyncWorlds.Characters.Character, discord_user_id: "991")

      case @stale do
        :submitted ->
          AsyncWorlds.Quests.Submissions.submit("123", "991", state.identity, "loop")

        :closed ->
          Ticks.close_tick(c.campaign.id, tick.id)

        :moved ->
          Repo.get!(AsyncWorlds.Quests.Progression, state.identity.progression_id)
          |> change(position_version: state.identity.position_version + 1)
          |> Repo.update!()

        :owner_changed ->
          character |> change(discord_user_id: "993") |> Repo.update!()

        :dm_revoked ->
          c.campaign |> change(dm_user_id: "457") |> Repo.update!()

        :guild_changed ->
          c.campaign |> change(discord_guild_id: "124") |> Repo.update!()
      end

      assert :ok = deliver(reminder)
      refute_received {:discord, :send_private, _}

      assert {:ok, %{status: :failed, last_error: "stale_notification", attempts: 0}} =
               Deliveries.fetch_delivery(c.campaign.id, reminder.id)

      assert {:ok, retried} = Deliveries.retry_delivery(c.campaign.id, reminder.id, 0)
      assert :ok = deliver(retried)
      refute_received {:discord, :send_private, _}
    end
  end

  test "all blocked publication succeeds and private commands retrieve only owned approved output and latest choice",
       c do
    {:ok, tick} = Ticks.open_tick(c.campaign.id)

    for {user, choice} <- [{"991", "loop"}, {"992", "finish"}] do
      {:ok, state} = AsyncWorlds.Quests.Submissions.player_state("123", user)
      {:ok, _} = AsyncWorlds.Quests.Submissions.submit("123", user, state.identity, choice)
    end

    {:ok, %{snapshot: snapshot}} = Ticks.close_tick(c.campaign.id, tick.id)
    {:ok, payload} = AsyncWorlds.Ticks.WorldResolver.resolve(snapshot)
    {:ok, %{draft: draft}} = Ticks.put_draft(c.campaign.id, tick.id, snapshot.revision, payload)
    context = %{campaign: c.campaign, user_id: "991"}

    assert {:ok, "No published personal result yet."} =
             AsyncWorlds.Discord.Commands.execute(:result, context)

    {:ok, preview} = Ticks.preview_draft(c.campaign.id, tick.id, draft.id)
    FakeAdapter.fail(:send_private, {:error, {:permanent, :forbidden}})
    FakeAdapter.fail(:send_public, {:error, {:permanent, :forbidden}})
    assert {:ok, %{status: :published}} = Ticks.publish_tick(c.campaign.id, tick.id, draft.id)
    for delivery <- Deliveries.list_deliveries(c.campaign.id), do: deliver(delivery)
    assert {:ok, result} = AsyncWorlds.Discord.Commands.execute(:result, context)

    assert result ==
             preview["players"]
             |> Enum.filter(&(&1["recipient_id"] == "991"))
             |> Enum.map_join("", & &1["content"])

    assert result =~ "Result\nHub"
    refute result =~ "Ending"
    refute result =~ "secret"
    assert {:ok, submission} = AsyncWorlds.Discord.Commands.execute(:submission, context)
    assert submission =~ "Latest choice: loop"
    assert {:ok, _} = AsyncWorlds.Discord.Commands.execute(:quest, context)

    assert {:error, :not_found} =
             AsyncWorlds.Discord.Commands.execute(:result, %{context | user_id: "993"})

    assert {:error, :already_published} = Ticks.publish_tick(c.campaign.id, tick.id, draft.id)
    assert Repo.aggregate(AsyncWorlds.Ticks.Publication, :count) == 1
    character = Repo.get_by!(AsyncWorlds.Characters.Character, discord_user_id: "991")
    character |> change(discord_user_id: "993") |> Repo.update!()

    assert {:ok, "No published personal result yet."} =
             AsyncWorlds.Discord.Commands.execute(:result, %{context | user_id: "993"})
  end

  test "published output chunk keys restart at zero per owner and shared renderer splits Unicode without hidden state",
       c do
    {:ok, tick} = Ticks.open_tick(c.campaign.id)
    {:ok, %{snapshot: snapshot}} = Ticks.close_tick(c.campaign.id, tick.id)
    {:ok, payload} = AsyncWorlds.Ticks.WorldResolver.resolve(snapshot)
    {:ok, %{draft: draft}} = Ticks.put_draft(c.campaign.id, tick.id, snapshot.revision, payload)
    {:ok, _} = Ticks.publish_tick(c.campaign.id, tick.id, draft.id)

    for user <- ["991", "992"] do
      assert Enum.any?(
               Deliveries.list_deliveries(c.campaign.id),
               &(&1.key == "tick:#{tick.id}:players:#{user}:0")
             )
    end

    long = String.duplicate("🦊", 5000)

    payload =
      update_in(payload["next_nodes"], fn nodes ->
        Enum.map(nodes, &put_in(&1["projection"]["text"], long))
      end)

    output = AsyncWorlds.Ticks.Output.render(payload, snapshot.data["campaign"])

    for user <- ["991", "992"] do
      messages = Enum.filter(output["players"], &(&1["recipient_id"] == user))
      assert length(messages) >= 3
      assert Enum.all?(messages, &(length(String.codepoints(&1["content"])) <= 2000))
      assert Enum.map_join(messages, "", & &1["content"]) =~ long
      refute Enum.map_join(messages, "", & &1["content"]) =~ "secret"
    end
  end

  test "pending personal publication cannot be delivered to a former character owner", c do
    {:ok, tick} = Ticks.open_tick(c.campaign.id)
    {:ok, %{snapshot: snapshot}} = Ticks.close_tick(c.campaign.id, tick.id)
    {:ok, payload} = AsyncWorlds.Ticks.WorldResolver.resolve(snapshot)
    {:ok, %{draft: draft}} = Ticks.put_draft(c.campaign.id, tick.id, snapshot.revision, payload)
    {:ok, _} = Ticks.publish_tick(c.campaign.id, tick.id, draft.id)

    result =
      Enum.find(
        Deliveries.list_deliveries(c.campaign.id),
        &(&1.key == "tick:#{tick.id}:players:991:0")
      )

    character = Repo.get_by!(AsyncWorlds.Characters.Character, discord_user_id: "991")

    {:ok, _} =
      Characters.update_character(c.campaign, "456", character.id, %{discord_user_id: "993"})

    assert :ok = deliver(result)
    refute_received {:discord, :send_private, _}

    assert {:ok, %{last_error: "stale_notification"}} =
             Deliveries.fetch_delivery(c.campaign.id, result.id)
  end

  test "persisted reminder survives adapter restart and ambiguous/interrupted sends never blindly retry",
       c do
    {:ok, _} = Ticks.open_tick(c.campaign.id)
    {:ok, 2} = AsyncWorlds.Ticks.PrivateNotifications.remind("123", "456", "102")

    reminders =
      Enum.filter(
        Deliveries.list_deliveries(c.campaign.id),
        &String.contains?(&1.key, ":reminder:")
      )

    [first, second] = reminders
    jobs = Repo.aggregate(Oban.Job, :count)
    FakeAdapter.fail(:send_private, {:error, {:ambiguous, :unknown_result}})
    assert {:cancel, :unknown_result} = deliver(first)
    assert_received {:discord, :send_private, {"991", _}}
    # Persisted sending claim represents a worker/application killed after an unknown send.
    assert {:ok, %{status: :sending}} = Deliveries.claim(second.id, 0)
    stop_supervised!(FakeAdapter)
    start_supervised!({FakeAdapter, owner: self()})
    assert {:ok, 2} = AsyncWorlds.Ticks.PrivateNotifications.remind("123", "456", "102")
    assert {:ok, 2} = AsyncWorlds.Ticks.PrivateNotifications.remind("123", "456", "104")
    assert Repo.aggregate(Oban.Job, :count) == jobs

    for reminder <- reminders do
      {:ok, reloaded} = Deliveries.fetch_delivery(c.campaign.id, reminder.id)
      assert :ok = deliver(reloaded)
      refute_received {:discord, :send_private, _}
      assert {:ok, %{status: :ambiguous}} = Deliveries.fetch_delivery(c.campaign.id, reminder.id)

      assert {:error, :confirmation_required} =
               Deliveries.retry_delivery(c.campaign.id, reminder.id, 0)
    end

    {:ok, state} = AsyncWorlds.Quests.Submissions.player_state("123", "991")
    {:ok, _} = AsyncWorlds.Quests.Submissions.submit("123", "991", state.identity, "loop")

    {:ok, retried} =
      Deliveries.retry_delivery(c.campaign.id, first.id, 0, confirm_ambiguous: true)

    assert :ok = deliver(retried)
    refute_received {:discord, :send_private, _}
  end

  test "long prompt payloads preserve only projected visible content through fake adapter", c do
    [hub, ending] = definition()["nodes"]

    condition = %{
      "type" => "character_flag",
      "key" => "classified",
      "flag_type" => "boolean",
      "value" => true
    }

    hidden =
      choice("hidden", "hub")
      |> Map.merge(%{
        "label" => "Hidden secret",
        "eligibility" => "hidden",
        "conditions" => [condition]
      })

    locked =
      choice("locked", "hub")
      |> Map.put("conditions", [condition])
      |> Map.put("label", "locked " <> String.duplicate("x", 2500))

    long = String.duplicate("🌍", 1900)

    definition =
      put_in(definition()["nodes"], [
        hub |> Map.put("text", long) |> Map.put("choices", [hidden, locked]),
        ending
      ])

    quest = Repo.one!(AsyncWorlds.Quests.Quest)
    {:ok, revision} = Quests.append_revision(c.campaign, "456", quest.id, definition)

    for character <- Repo.all(AsyncWorlds.Characters.Character) do
      {:ok, _} = Quests.swap(c.campaign, "456", character.id, revision.id)
    end

    {:ok, _} = Ticks.open_tick(c.campaign.id)

    for user <- ["991", "992"] do
      prompts = Enum.filter(Deliveries.list_deliveries(c.campaign.id), &(&1.recipient_id == user))
      text = Enum.map_join(prompts, "", & &1.content)
      assert text =~ long
      assert text =~ "locked "
      assert text =~ " — Not available"
      refute text =~ "Hidden secret"
      refute text =~ "classified"
      refute text =~ "outcomes"

      for prompt <- prompts do
        assert :ok = deliver(prompt)
        assert_received {:discord, :send_private, {^user, payload}}
        assert length(String.codepoints(payload.content)) <= 2000
        assert payload.allowed_mentions == %{parse: []}
      end
    end
  end

  test "private latest approved result ignores newer open/resolving/review states and commands send no proactive notifications",
       c do
    {:ok, tick} = Ticks.open_tick(c.campaign.id)
    {:ok, state} = AsyncWorlds.Quests.Submissions.player_state("123", "991")
    {:ok, _} = AsyncWorlds.Quests.Submissions.submit("123", "991", state.identity, "loop")
    {:ok, %{snapshot: snapshot}} = Ticks.close_tick(c.campaign.id, tick.id)
    {:ok, payload} = AsyncWorlds.Ticks.WorldResolver.resolve(snapshot)
    {:ok, %{draft: draft}} = Ticks.put_draft(c.campaign.id, tick.id, snapshot.revision, payload)
    {:ok, _} = Ticks.publish_tick(c.campaign.id, tick.id, draft.id)
    context = %{campaign: c.campaign, user_id: "991"}
    {:ok, approved} = AsyncWorlds.Discord.Commands.execute(:result, context)
    {:ok, next} = Ticks.open_tick(c.campaign.id)
    assert {:ok, ^approved} = AsyncWorlds.Discord.Commands.execute(:result, context)
    {:ok, %{snapshot: snapshot}} = Ticks.close_tick(c.campaign.id, next.id)
    assert {:ok, ^approved} = AsyncWorlds.Discord.Commands.execute(:result, context)
    {:ok, payload} = AsyncWorlds.Ticks.WorldResolver.resolve(snapshot)
    {:ok, _} = Ticks.put_draft(c.campaign.id, next.id, snapshot.revision, payload)

    for _ <- 1..3,
        do: assert({:ok, ^approved} = AsyncWorlds.Discord.Commands.execute(:result, context))

    assert {:ok, :result, :player} = AsyncWorlds.Discord.Commands.route(%{name: "result"})
    refute_received {:discord, :send_private, _}
  end

  test "completed player's last applicable result and submission survive later world-only publications",
       c do
    {:ok, tick} = Ticks.open_tick(c.campaign.id)
    {:ok, state} = AsyncWorlds.Quests.Submissions.player_state("123", "991")
    {:ok, _} = AsyncWorlds.Quests.Submissions.submit("123", "991", state.identity, "finish")

    publish = fn tick ->
      {:ok, %{snapshot: snapshot}} = Ticks.close_tick(c.campaign.id, tick.id)
      {:ok, payload} = AsyncWorlds.Ticks.WorldResolver.resolve(snapshot)
      {:ok, %{draft: draft}} = Ticks.put_draft(c.campaign.id, tick.id, snapshot.revision, payload)
      {:ok, _} = Ticks.publish_tick(c.campaign.id, tick.id, draft.id)
    end

    publish.(tick)
    context = %{campaign: c.campaign, user_id: "991"}
    {:ok, result} = AsyncWorlds.Discord.Commands.execute(:result, context)
    {:ok, submission} = AsyncWorlds.Discord.Commands.execute(:submission, context)
    assert submission =~ "Latest choice: finish"
    {:ok, next} = Ticks.open_tick(c.campaign.id)
    publish.(next)
    assert {:ok, ^result} = AsyncWorlds.Discord.Commands.execute(:result, context)
    assert {:ok, ^submission} = AsyncWorlds.Discord.Commands.execute(:submission, context)
  end

  test "unguarded legacy personal outputs fail closed for pending and targeted retries", c do
    {:ok, tick} = Ticks.open_tick(c.campaign.id)

    for status <- [:pending, :failed] do
      {:ok, legacy} =
        Deliveries.enqueue(c.campaign.id, tick.id, %{
          key: "tick:#{tick.id}:players:991:#{status}",
          kind: :private,
          recipient_id: "991",
          content: "Legacy private result"
        })

      legacy =
        legacy
        |> change(status: status, error_class: if(status == :failed, do: :permanent))
        |> Repo.update!()

      legacy =
        if status == :failed do
          {:ok, retry} = Deliveries.retry_delivery(c.campaign.id, legacy.id, 0)
          retry
        else
          legacy
        end

      assert :ok = deliver(legacy)
      refute_received {:discord, :send_private, _}

      assert {:ok, %{status: :failed, last_error: "stale_notification", attempts: 0}} =
               Deliveries.fetch_delivery(c.campaign.id, legacy.id)
    end
  end

  defp deliver(d),
    do:
      DeliverDiscord.perform(%Oban.Job{
        args: %{"delivery_id" => d.id, "generation" => d.generation}
      })

  test "opening commits bounded private prompts for each owner; blocked DMs are visible and do not undo open",
       c do
    assert {:ok, tick} = Ticks.open_tick(c.campaign.id)
    prompts = Deliveries.list_deliveries(c.campaign.id) |> Enum.filter(&(&1.kind == :private))
    assert Enum.map(prompts, & &1.recipient_id) == ["991", "992"]

    assert Enum.all?(
             prompts,
             &(&1.content =~ "Hub" and &1.content =~ "/quest" and not (&1.content =~ "secret"))
           )

    assert Enum.map(prompts, & &1.key) ==
             for(user <- ["991", "992"], do: "tick:#{tick.id}:prompt:#{user}:0:opened")

    assert {:error, :active_tick} = Ticks.open_tick(c.campaign.id)
    FakeAdapter.fail(:send_private, {:error, {:permanent, :forbidden}})

    for prompt <- prompts do
      assert {:cancel, :forbidden} = deliver(prompt)

      assert {:ok, %{status: :failed, last_error: "forbidden"}} =
               Deliveries.fetch_delivery(c.campaign.id, prompt.id)

      assert :ok = deliver(prompt)
    end

    assert {:ok, %{status: :open}} = Ticks.fetch_tick(c.campaign.id, tick.id)
    assert length(Deliveries.list_deliveries(c.campaign.id)) == 3
  end
end
