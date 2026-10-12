defmodule AsyncWorlds.Discord.DebugNotificationsIntegrationTest do
  use AsyncWorlds.DataCase, async: false
  import AsyncWorlds.QuestFixtures
  alias AsyncWorlds.{Campaigns, Characters, Deliveries, PlayerAccess, Quests, Repo, Ticks}
  alias AsyncWorlds.Discord.{DebugSessions, Dispatcher, FakeAdapter, PrivateRetrieval}
  alias AsyncWorlds.Quests.Submissions
  alias AsyncWorlds.Ticks.{PrivateNotifications, WorldResolver}

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
      Quests.create_quest(campaign, "456", %{content_id: "test", name: "Test"}, definition())

    characters =
      for {name, owner} <- [{"A", nil}, {"B", nil}, {"Linked", "999"}, {"DM owned", "456"}] do
        {:ok, character} =
          Characters.create_character(campaign, "456", %{name: name, discord_user_id: owner})

        {:ok, _} = Quests.assign(campaign, "456", character.id, revision.id)
        character
      end

    %{
      campaign: campaign,
      a: Enum.at(characters, 0),
      b: Enum.at(characters, 1),
      linked: Enum.at(characters, 2),
      own: Enum.at(characters, 3),
      characters: characters
    }
  end

  defp access(c, character) do
    {:ok, _} = DebugSessions.transition("123", "456", {:player, character.id})
    {:ok, context} = PlayerAccess.context(c.campaign, "456")
    context.access
  end

  defp invoke(name, user \\ 456) do
    Dispatcher.handle(
      %{
        type: 2,
        id: System.unique_integer([:positive]),
        application_id: 111,
        guild_id: 123,
        member: %{user_id: user},
        token: "private-token",
        data: %{name: name}
      }, adapter: FakeAdapter, guild_id: "123", application_id: "111")
  end

  defp deliver(d),
    do:
      AsyncWorlds.Workers.DeliverDiscord.perform(%Oban.Job{
        args: %{"delivery_id" => d.id, "generation" => d.generation}
      })

  defp publish(c, tick) do
    {:ok, %{snapshot: snapshot}} = Ticks.close_tick(c.campaign.id, tick.id)
    {:ok, payload} = WorldResolver.resolve(snapshot)
    {:ok, %{draft: draft}} = Ticks.put_draft(c.campaign.id, tick.id, snapshot.revision, payload)
    {:ok, _} = Ticks.publish_tick(c.campaign.id, tick.id, draft.id)
  end

  test "accountless prompts/reminders are distinct, guarded by subject, and independent of selected persona",
       c do
    {:ok, _} = DebugSessions.transition("123", "456", {:messages, true})
    {:ok, _tick} = Ticks.open_tick(c.campaign.id)
    prompts = Enum.filter(Deliveries.list_deliveries(c.campaign.id), &(&1.kind == :private))
    assert length(prompts) == 5
    assert length(Enum.uniq_by(prompts, & &1.key)) == 5

    for character <- [c.a, c.b] do
      prompt = Enum.find(prompts, &(&1.guard["character_id"] == character.id))
      assert prompt.recipient_id == "456"
      assert prompt.content =~ "Player: #{character.name}"
      assert :ok = deliver(prompt)
    end

    assert Enum.count(prompts, &(&1.guard["character_id"] == c.linked.id)) == 2
    assert Enum.count(prompts, &(&1.guard["character_id"] == c.own.id)) == 1
    assert {:ok, 4} = PrivateNotifications.remind("123", "456", "101")
    assert {:ok, 4} = PrivateNotifications.remind("123", "456", "102")

    reminders =
      Enum.filter(
        Deliveries.list_deliveries(c.campaign.id),
        &String.contains?(&1.key, ":reminder:")
      )

    assert length(reminders) == 5
    subject = access(c, c.a)
    {:ok, state} = Submissions.player_state("123", subject)
    {:ok, _} = Submissions.submit("123", subject, state.identity, "loop")
    a_reminder = Enum.find(reminders, &(&1.guard["character_id"] == c.a.id))
    b_reminder = Enum.find(reminders, &(&1.guard["character_id"] == c.b.id))
    assert :ok = deliver(a_reminder)

    assert Repo.get!(AsyncWorlds.Deliveries.Delivery, a_reminder.id).last_error ==
             "stale_notification"

    assert :ok = deliver(b_reminder)
    assert Repo.get!(AsyncWorlds.Deliveries.Delivery, b_reminder.id).status == :sent
  end

  test "published deliveries and history isolate characters sharing the DM recipient", c do
    {:ok, _} = DebugSessions.transition("123", "456", {:messages, true})
    {:ok, tick} = Ticks.open_tick(c.campaign.id)

    for character <- c.characters do
      subject = access(c, character)
      {:ok, state} = Submissions.player_state("123", subject)

      {:ok, _} =
        Submissions.submit(
          "123",
          subject,
          state.identity,
          if(character.id == c.b.id, do: "finish", else: "loop")
        )
    end

    publish(c, tick)

    results =
      Enum.filter(
        Deliveries.list_deliveries(c.campaign.id),
        &(&1.guard["type"] == "character_delivery")
      )

    assert length(results) == 5
    for result <- results, do: assert(:ok == deliver(result))

    for character <- [c.a, c.b] do
      _ = access(c, character)
      assert {:ok, result} = invoke("result")
      assert result =~ "Testing as #{character.name}"
      assert result =~ "Player: #{character.name}"
      other = if character.id == c.a.id, do: "B", else: "A"
      refute result =~ "Player: #{other}"
      assert {:ok, submission} = invoke("submission")

      assert submission =~
               "Latest choice: #{if character.id == c.b.id, do: "finish", else: "loop"}"
    end

    _ = access(c, c.linked)
    assert {:ok, linked_result} = invoke("result")
    refute linked_result =~ "Player copy:"
    refute linked_result =~ "Player: A"
    {:ok, _} = DebugSessions.transition("123", "456", :off)
    assert {:ok, own_result} = invoke("result")
    refute own_result =~ "Player: A"
    refute own_result =~ "Player: B"
    refute own_result =~ "Player copy:"

    {:ok, _} =
      Characters.update_character(c.campaign, "456", c.linked.id, %{discord_user_id: "993"})

    assert {:ok, "No published personal result yet."} = PrivateRetrieval.result("123", "993")
    assert {:ok, :no_submission} = PrivateRetrieval.submission("123", "993")
    subject = access(c, c.linked)
    assert {:ok, historic} = PrivateRetrieval.result("123", subject)
    assert historic =~ "Hub"
    assert {:ok, historic_choice} = PrivateRetrieval.submission("123", subject)
    assert historic_choice =~ "Latest choice: loop"
  end

  test "DM change or owner change suppresses queued DM-controlled/copy messages", c do
    {:ok, _} = DebugSessions.transition("123", "456", {:messages, true})
    {:ok, tick} = Ticks.open_tick(c.campaign.id)
    publish(c, tick)

    deliveries =
      Enum.filter(
        Deliveries.list_deliveries(c.campaign.id),
        &(&1.guard["type"] == "character_delivery")
      )

    copy = Enum.find(deliveries, &(&1.guard["audience"] == "dm_copy"))
    accountless = Enum.find(deliveries, &(&1.guard["character_id"] == c.a.id))

    {:ok, _} =
      Characters.update_character(c.campaign, "456", c.linked.id, %{discord_user_id: "993"})

    assert :ok = deliver(copy)
    assert Repo.get!(AsyncWorlds.Deliveries.Delivery, copy.id).last_error == "stale_notification"

    {:ok, _} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "123",
        dm_user_id: "457",
        public_channel_id: "789"
      })

    assert :ok = deliver(accountless)

    assert Repo.get!(AsyncWorlds.Deliveries.Delivery, accountless.id).last_error ==
             "stale_notification"

    refute_received {:discord, :send_private, _}
  end
end
