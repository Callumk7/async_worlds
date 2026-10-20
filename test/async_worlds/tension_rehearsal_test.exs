defmodule AsyncWorlds.TensionRehearsalTest do
  @moduledoc """
  ENG-96 executable rehearsal: an explicitly adopted, quest-free campaign over three
  openings and two publications. Exercises Dispatcher -> Commands -> domain ->
  PostgreSQL -> close/review/publication -> durable delivery with the supervised fake
  Discord adapter. Not live Discord evidence; see docs/tension-led-rehearsal.md.
  """
  use AsyncWorlds.DataCase, async: false
  alias AsyncWorlds.{Campaigns, Characters, Deliveries, Repo, TensionDiscussions, Tensions, Ticks}
  alias AsyncWorlds.Clocks.Clock
  alias AsyncWorlds.Discord.{Dispatcher, FakeAdapter}
  alias AsyncWorlds.Tensions.{Discussion, DiscussionIntent}
  alias AsyncWorlds.Ticks.{Chronicle, Opening, WorldResolver}
  alias AsyncWorlds.Workers.{DeliverDiscord, OpenTensionDiscussion}

  @secrets ["GOBLIN REINFORCEMENTS", "PRIVATE INTENT", "SECRET ASSET", "DM NOTE", "3/4"]

  setup do
    start_supervised!({FakeAdapter, owner: self()})
    previous = Application.fetch_env!(:async_worlds, :discord)
    Application.put_env(:async_worlds, :discord, enabled: true, adapter: FakeAdapter)
    on_exit(fn -> Application.put_env(:async_worlds, :discord, previous) end)

    {:ok, c} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "123",
        dm_user_id: "456",
        public_channel_id: "789"
      })

    chars =
      for {name, owner} <- [rook: "999", wren: "997", absent: "998"], into: %{} do
        {:ok, ch} =
          Characters.create_character(c, "456", %{
            name: String.capitalize("#{name}"),
            discord_user_id: owner
          })

        {name, ch}
      end

    {:ok, battle} =
      Tensions.create_tension(
        c.id,
        %{
          name: "Battle in the Reach",
          description: "Goblins press the elven line at the river crossing.",
          audience: :public
        },
        "dm"
      )

    {:ok, balance} =
      Tensions.create_clock(
        c.id,
        battle.id,
        %{
          name: "Balance of battle",
          mode: :tug_of_war,
          segments: 8,
          filled: 4,
          visibility: :public,
          influences: "Goblin numbers against elven discipline",
          full_description: "Goblin victory",
          empty_description: "Elven victory"
        },
        "dm"
      )

    {:ok, supply} =
      Tensions.create_clock(
        c.id,
        battle.id,
        %{name: "Elven supply", segments: 4, filled: 3, visibility: :known},
        "dm"
      )

    {:ok, reinforcements} =
      Tensions.create_clock(
        c.id,
        battle.id,
        %{name: "GOBLIN REINFORCEMENTS", segments: 6, background_rate: 1},
        "dm"
      )

    # Unattended pressure: nobody needs to act for it to move.
    {:ok, harvest} =
      Tensions.create_tension(
        c.id,
        %{
          name: "Threatened harvest",
          description: "Blight in the lowland fields.",
          audience: :public
        },
        "dm"
      )

    {:ok, blight} =
      Tensions.create_clock(
        c.id,
        harvest.id,
        %{name: "Blight", segments: 6, visibility: :public, background_rate: 1},
        "dm"
      )

    Map.merge(chars, %{
      c: c,
      battle: battle,
      harvest: harvest,
      balance: balance,
      supply: supply,
      reinforcements: reinforcements,
      blight: blight,
      scope: %{campaign: c, discord_user_id: "456"},
      opts: [adapter: FakeAdapter, guild_id: "123", application_id: "111"]
    })
  end

  defp slash(x, name, options, user) do
    Dispatcher.handle(
      %{
        type: 2,
        id: System.unique_integer([:positive]),
        application_id: 111,
        guild_id: 123,
        member: %{user_id: user},
        token: "test-only",
        data: %{name: name, options: options}
      },
      x.opts
    )
  end

  defp intent(x, action, attrs, user) do
    options =
      Enum.map(attrs, fn {key, value} ->
        %{name: key, type: if(is_integer(value), do: 4, else: 3), value: value}
      end)

    slash(x, "intent", [%{name: action, type: 1, options: options}], user)
  end

  defp commit(x, tick, tension, user, intention, approach) do
    {:ok, _} =
      intent(
        x,
        "edit",
        %{
          "tick" => tick.id,
          "tension" => tension.id,
          "version" => 0,
          "intention" => intention,
          "approach" => approach
        },
        user
      )

    {:ok, text} =
      intent(x, "confirm", %{"tick" => tick.id, "tension" => tension.id, "version" => 1}, user)

    assert text =~ "confirmed"
  end

  defp discussion!(tension), do: Repo.get_by!(Discussion, tension_id: tension.id)

  defp create_thread(tension, thread_id) do
    FakeAdapter.fail(:create_public_thread, {:ok, %{thread_id: thread_id}})
    assert :ok = OpenTensionDiscussion.run(discussion!(tension).id, FakeAdapter)
    FakeAdapter.fail(:create_public_thread, nil)
    assert discussion!(tension).thread_id == thread_id
  end

  defp deliver_pending(c) do
    for d <- Deliveries.list_deliveries(c.id), d.status == :pending do
      DeliverDiscord.perform(%Oban.Job{
        args: %{"delivery_id" => d.id, "generation" => d.generation}
      })
    end
  end

  defp freeze(x, tick) do
    {:ok, %{snapshot: s}} = Ticks.close_tick(x.c.id, tick.id)
    {:ok, payload} = WorldResolver.resolve(s)
    {:ok, %{draft: d}} = Ticks.put_draft(x.c.id, tick.id, s.revision, payload)
    {s, d}
  end

  defp edit(x, tick, draft, op, reason \\ "Reviewed account") do
    {:ok, %{draft: next}} = Ticks.edit_draft(x.c.id, tick.id, draft.id, op, "456", reason)
    next
  end

  defp flush_discord do
    receive do
      {:discord, _, _} -> flush_discord()
    after
      0 -> :ok
    end
  end

  defp filled(clock), do: Repo.get!(Clock, clock.id).filled

  defp public_text(c) do
    deliveries = for d <- Deliveries.list_deliveries(c.id), d.kind == :public, do: d.content
    intents = for i <- Repo.all(DiscussionIntent), do: "#{i.content}\n#{i.overview}"
    Enum.join(deliveries ++ intents, "\n")
  end

  defp refute_leaks(c) do
    text = public_text(c)
    for secret <- @secrets, do: refute(text =~ secret, "public output leaked #{inspect(secret)}")
  end

  test "legacy campaigns keep quest-centred entry points until the DM explicitly adopts", x do
    {:ok, legacy} = Opening.prepare(x.scope)
    legacy_text = Enum.map_join(legacy.messages, "\n", & &1.content)
    assert legacy_text =~ "Rook: No quest decision required."
    refute legacy_text =~ "without a quest"
    {:ok, text} = slash(x, "quest", [], 999)
    assert text =~ "after your DM assigns one"

    assert {:error, :unauthorized} =
             Campaigns.set_tension_participation(%{x.scope | discord_user_id: "999"}, true)

    assert {:ok, %{tension_participation: true}} =
             Campaigns.set_tension_participation(x.scope, true)

    # Adoption changes inputs, so an earlier prepared preview cannot be opened.
    assert {:error, :stale_preparation} = Opening.open(x.scope, legacy.token)

    {:ok, adopted} = Opening.prepare(x.scope)
    adopted_text = Enum.map_join(adopted.messages, "\n", & &1.content)
    assert adopted_text =~ "Everyone can take part without a quest"
    assert adopted_text =~ "/intent"
    refute adopted_text =~ "No quest decision required"
    refute adopted_text =~ "Run /quest"
    {:ok, text} = slash(x, "quest", [], 999)
    assert text =~ "none is needed to play"
    assert text =~ "/intent view"

    # Leaving again restores the old wording without touching saved state.
    assert {:ok, %{tension_participation: false}} =
             Campaigns.set_tension_participation(x.scope, false)

    {:ok, again} = Opening.prepare(x.scope)
    assert Enum.map(again.messages, & &1.content) == Enum.map(legacy.messages, & &1.content)
  end

  test "two-tick quest-free rehearsal: commitments, failures, recovery, restart and connected history",
       x do
    {:ok, _} = Campaigns.set_tension_participation(x.scope, true)

    # --- Tick 1 opens with the inspected Tension-led briefing.
    {:ok, prep} = Opening.prepare(x.scope, %{"narration" => "Smoke rises over the Reach."})
    {:ok, tick1} = Opening.open(x.scope, prep.token)
    assert Repo.get_by(AsyncWorlds.Quests.Progression, character_id: x.rook.id) == nil

    # Controlled thread recovery: an unknown create result is never retried blindly.
    FakeAdapter.fail(:create_public_thread, {:error, {:ambiguous, :unknown_result}})

    assert {:cancel, :recovery_required} =
             OpenTensionDiscussion.run(discussion!(x.battle).id, FakeAdapter)

    FakeAdapter.fail(:create_public_thread, nil)
    assert :ok = OpenTensionDiscussion.run(discussion!(x.battle).id, FakeAdapter)
    {:ok, expected} = TensionDiscussions.get(x.scope, x.battle.id)
    assert expected.status == "ambiguous"

    FakeAdapter.fail(
      :inspect_thread,
      {:ok, %{guild_id: "123", parent_id: "789", type: 11, archived: false}}
    )

    assert {:ok, _} =
             TensionDiscussions.recover(
               x.scope,
               x.battle.id,
               expected,
               {:bind, "9101"},
               FakeAdapter
             )

    FakeAdapter.fail(:inspect_thread, nil)
    assert :ok = OpenTensionDiscussion.run(discussion!(x.battle).id, FakeAdapter)
    assert discussion!(x.battle).thread_id == "9101"
    create_thread(x.harvest, "9102")

    briefing =
      Repo.one!(
        from i in DiscussionIntent,
          where: i.key == ^"#{tick1.id}:opening" and i.discussion_id == ^discussion!(x.battle).id
      )

    assert briefing.content =~ "4/8"
    assert briefing.content =~ "Elven supply"
    assert briefing.content =~ "/intent"

    # --- Players commit broadly. Rook contributes to two Tensions; Wren changes then withdraws.
    commit(
      x,
      tick1,
      x.battle,
      999,
      "PRIVATE INTENT hold the crossing",
      "SECRET ASSET the Ash Company and the neighbouring lords"
    )

    commit(x, tick1, x.harvest, 999, "PRIVATE INTENT get the grain in early", "Villagers' carts")
    commit(x, tick1, x.battle, 997, "PRIVATE INTENT scout the ford", "")

    {:ok, _} =
      intent(
        x,
        "edit",
        %{
          "tick" => tick1.id,
          "tension" => x.battle.id,
          "version" => 2,
          "intention" => "PRIVATE INTENT harry the goblin flank"
        },
        997
      )

    {:ok, stale} =
      intent(x, "confirm", %{"tick" => tick1.id, "tension" => x.battle.id, "version" => 2}, 997)

    assert stale =~ "Nothing changed: stale version"

    {:ok, _} =
      intent(x, "confirm", %{"tick" => tick1.id, "tension" => x.battle.id, "version" => 3}, 997)

    commit(x, tick1, x.harvest, 997, "PRIVATE INTENT pray at the shrine", "")

    {:ok, text} =
      intent(x, "withdraw", %{"tick" => tick1.id, "tension" => x.harvest.id, "version" => 2}, 997)

    assert text =~ "withdrawn"

    {:ok, roster} = intent(x, "roster", %{"tick" => tick1.id}, 456)
    assert roster =~ "harry the goblin flank"
    assert roster =~ "absent"

    # Failed delivery is retried explicitly without touching the tick.
    post = Enum.find(Deliveries.list_deliveries(x.c.id), &(&1.recipient_id == "9101"))
    FakeAdapter.fail(:send_public, {:error, {:permanent, :forbidden}})

    assert {:cancel, :forbidden} =
             DeliverDiscord.perform(%Oban.Job{
               args: %{"delivery_id" => post.id, "generation" => post.generation}
             })

    FakeAdapter.fail(:send_public, nil)

    {:ok, retried} =
      Deliveries.retry_delivery(
        x.c.id,
        post.id,
        Repo.get!(Deliveries.Delivery, post.id).generation
      )

    assert :ok =
             DeliverDiscord.perform(%Oban.Job{
               args: %{"delivery_id" => retried.id, "generation" => retried.generation}
             })

    assert Repo.get!(Deliveries.Delivery, post.id).status == :sent
    assert Ticks.active_tick(x.c.id).status == :open

    # Nothing is established by commitments alone.
    assert {filled(x.balance), filled(x.reinforcements), filled(x.blight)} == {4, 0, 0}

    # --- Close despite the absent player; late changes are rejected.
    {snapshot, draft} = freeze(x, tick1)

    assert {:error, :tick_closed} =
             AsyncWorlds.TensionCommitments.change(
               "123",
               "997",
               tick1.id,
               x.battle.id,
               4,
               :edit,
               %{
                 "intention" => "late"
               }
             )

    frozen = snapshot.data["tension_commitments"]
    absent = Enum.find(frozen, &(&1["character_id"] == x.absent.id))
    assert Enum.all?(absent["commitments"], &(&1["state"] == "absent"))

    draft =
      edit(x, tick1, draft, %{
        type: "synthesis",
        tension_id: x.battle.id,
        interpretation: "DM NOTE Ash Company and Wren's raid together blunt the assault",
        deferred: [x.absent.id]
      })

    draft =
      edit(x, tick1, draft, %{
        type: "world",
        key: "crossing",
        event: %{
          title: "The Ash Company holds the crossing",
          text: "Two assaults are repelled and villagers escape, but the captain is wounded.",
          kind: "event",
          audience: "public",
          references: [
            %{entity: "tension", id: x.battle.id},
            %{entity: "character", id: x.rook.id}
          ],
          follow_on: ["new:crossing:1"],
          changes: [
            %{entity: "clock", id: x.balance.id, attrs: %{delta: -2}},
            %{
              entity: "tension",
              id: nil,
              attrs: %{
                name: "The wounded captain",
                audience: "public",
                description: "The Ash Company's captain lies feverish."
              }
            }
          ]
        }
      })

    draft =
      edit(x, tick1, draft, %{
        type: "world",
        key: "omens",
        event: %{
          title: "Crows gather over the lowlands",
          text: "Farmers read the flocks as a poor omen for the harvest.",
          kind: "event",
          audience: "public",
          references: [%{entity: "tension", id: x.harvest.id}],
          changes: []
        }
      })

    # Draft consequences are not facts: no live change and no player history yet.
    assert {filled(x.balance), filled(x.blight)} == {4, 0}
    assert {:ok, %{items: []}} = Chronicle.list("123", "999", :player)

    assert {:ok, _} = Ticks.publish_tick(x.c.id, tick1.id, draft.id)
    assert {:error, :already_published} = Ticks.publish_tick(x.c.id, tick1.id, draft.id)
    # Background pressure moved once; the DM adjustment applied once.
    assert {filled(x.balance), filled(x.reinforcements), filled(x.blight), filled(x.supply)} ==
             {2, 1, 1, 3}

    captain =
      Repo.get_by!(AsyncWorlds.Tensions.Tension, campaign_id: x.c.id, name: "The wounded captain")

    assert captain.audience == :public and captain.status == :ongoing
    refute_leaks(x.c)

    # --- Restart the transport process; durable outbox work continues from PostgreSQL.
    stop_supervised!(FakeAdapter)
    start_supervised!({FakeAdapter, owner: self()})
    deliver_pending(x.c)
    assert Enum.all?(Deliveries.list_deliveries(x.c.id), &(&1.status == :sent))
    {:ok, %{items: items}} = Chronicle.list("123", "999", :player)

    assert Enum.map(items, & &1["title"]) |> Enum.sort() == [
             "Crows gather over the lowlands",
             "The Ash Company holds the crossing"
           ]

    refute Jason.encode!(items) =~ "DM NOTE"

    # --- Tick 2: threads are reused; the follow-on Tension gets its own conversation.
    flush_discord()
    {:ok, tick2} = Ticks.open_tick(x.c.id)
    assert :ok = OpenTensionDiscussion.run(discussion!(x.battle).id, FakeAdapter)
    refute_received {:discord, :create_public_thread, _}
    create_thread(captain, "9103")

    reused =
      Repo.one!(
        from i in DiscussionIntent,
          where: i.key == ^"#{tick2.id}:opening" and i.discussion_id == ^discussion!(x.battle).id
      )

    assert reused.content =~ "2/8"

    overview =
      Repo.get!(
        AsyncWorlds.Ticks.Briefing,
        Repo.get_by!(AsyncWorlds.Ticks.Briefing, tick_id: tick2.id).id
      )

    assert inspect(overview.outputs) =~ "without a quest"

    commit(
      x,
      tick2,
      captain,
      999,
      "PRIVATE INTENT fetch a healer from the abbey",
      "SECRET ASSET my own coin"
    )

    commit(x, tick2, x.battle, 999, "PRIVATE INTENT keep the Ash Company on the line", "")
    # Wren is missing this tick.

    {_snapshot2, draft2} = freeze(x, tick2)

    draft2 =
      edit(x, tick2, draft2, %{
        type: "world",
        key: "harvest-in",
        event: %{
          title: "The harvest is brought in",
          text: "The villagers race the blight and save most of the grain.",
          kind: "resolution",
          audience: "public",
          references: [%{entity: "tension", id: x.harvest.id}],
          changes: [%{entity: "tension", id: x.harvest.id, attrs: %{status: "resolved"}}]
        }
      })

    draft2 =
      edit(x, tick2, draft2, %{
        type: "world",
        key: "healer",
        event: %{
          title: "A healer reaches the captain",
          text: "The abbey's healer arrives; the fever breaks, slowly.",
          kind: "event",
          audience: "public",
          references: [%{entity: "tension", id: captain.id}],
          changes: []
        }
      })

    assert {:ok, _} = Ticks.publish_tick(x.c.id, tick2.id, draft2.id)
    assert Repo.get!(AsyncWorlds.Tensions.Tension, x.harvest.id).status == :resolved
    assert Repo.get!(AsyncWorlds.Tensions.Tension, x.battle.id).status == :ongoing
    # Unattended pressures advanced once more; the Resolution paused the settled blight.
    assert {filled(x.balance), filled(x.reinforcements), filled(x.blight)} == {2, 2, 2}
    assert Repo.get!(Clock, x.blight.id).paused
    refute Repo.get!(Clock, x.reinforcements.id).paused
    deliver_pending(x.c)
    refute_leaks(x.c)

    # --- Tick 3 opening: the resolved situation is historical, the battle continues.
    {:ok, tick3} = Ticks.open_tick(x.c.id)

    harvest_open =
      Repo.one!(
        from i in DiscussionIntent,
          where: i.key == ^"#{tick3.id}:opening" and i.discussion_id == ^discussion!(x.harvest).id
      )

    assert harvest_open.content =~ "Historical — resolved"

    battle_open =
      Repo.one!(
        from i in DiscussionIntent,
          where: i.key == ^"#{tick3.id}:opening" and i.discussion_id == ^discussion!(x.battle).id
      )

    assert battle_open.content =~ "Discuss plans"

    # The chronicle explains how the world reached its state, from several entry points.
    {:ok, %{items: captain_history}} =
      Chronicle.list("123", "999", :player, %{"entity" => "tension", "entity_id" => captain.id})

    assert Enum.map(captain_history, & &1["title"]) == [
             "A healer reaches the captain",
             "The Ash Company holds the crossing"
           ]

    {:ok, %{items: harvest_history}} =
      Chronicle.list("123", "997", :player, %{"entity" => "tension", "entity_id" => x.harvest.id})

    assert Enum.map(harvest_history, & &1["title"]) == [
             "The harvest is brought in",
             "Crows gather over the lowlands"
           ]

    {:ok, %{items: rook_history}} =
      Chronicle.list("123", "998", :player, %{"entity" => "character", "entity_id" => x.rook.id})

    assert Enum.map(rook_history, & &1["title"]) == ["The Ash Company holds the crossing"]

    {:ok, shown} =
      slash(
        x,
        "chronicle",
        [
          %{
            name: "show",
            type: 1,
            options: [
              %{name: "tick", type: 3, value: to_string(tick1.id)},
              %{name: "event", type: 3, value: "crossing"}
            ]
          }
        ],
        998
      )

    assert shown =~ "The wounded captain"
    refute shown =~ "DM NOTE"
    refute_leaks(x.c)
    assert Ticks.latest_published_tick(x.c.id).id == tick2.id
  end
end
