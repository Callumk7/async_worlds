defmodule AsyncWorlds.TensionDiscussionsTest do
  use AsyncWorlds.DataCase, async: false
  alias AsyncWorlds.{Campaigns, Deliveries, Repo, TensionDiscussions, Tensions, Ticks}
  alias AsyncWorlds.Tensions.{Discussion, DiscussionIntent}
  alias AsyncWorlds.Ticks.WorldResolver
  alias AsyncWorlds.Discord.FakeAdapter
  alias AsyncWorlds.Workers.{DeliverDiscord, OpenTensionDiscussion}

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

    {:ok, t} =
      Tensions.create_tension(
        c.id,
        %{name: "Battle", description: "The river is contested", audience: :public},
        "dm"
      )

    %{c: c, t: t, scope: %{campaign: c, discord_user_id: "456"}}
  end

  defp freeze(c, tick) do
    {:ok, %{snapshot: s}} = Ticks.close_tick(c.id, tick.id)
    {:ok, p} = WorldResolver.resolve(s)
    {:ok, %{draft: d}} = Ticks.put_draft(c.id, tick.id, s.revision, p)
    d
  end

  defp event(c, tick, draft, t, kind \\ "event") do
    Ticks.edit_draft(
      c.id,
      tick.id,
      draft.id,
      %{
        type: "world",
        key: "crossing",
        event: %{
          title: "The crossing holds",
          text: "Another season gained",
          kind: kind,
          audience: "public",
          changes: [
            %{
              entity: "tension",
              id: t.id,
              attrs:
                if(kind == "resolution",
                  do: %{status: "resolved"},
                  else: %{description: "The crossing holds"}
                )
            }
          ]
        }
      },
      "456",
      "Reviewed"
    )
  end

  defp dispatch(t) do
    d = Repo.get_by!(Discussion, tension_id: t.id)
    assert :ok = OpenTensionDiscussion.run(d.id, FakeAdapter)
    Repo.get!(Discussion, d.id)
  end

  defp deliver(d) do
    assert :ok =
             DeliverDiscord.perform(%Oban.Job{
               args: %{"delivery_id" => d.id, "generation" => d.generation}
             })
  end

  test "disposable adapter demo: unattended open, publish, next open reuse, Resolution and immutable history",
       x do
    {:ok, _} =
      Tensions.create_clock(
        x.c.id,
        x.t.id,
        %{
          name: "Supply",
          segments: 4,
          visibility: :public,
          filled: 1,
          influences: "River traffic"
        },
        "dm"
      )

    {:ok, _} =
      Tensions.create_clock(
        x.c.id,
        x.t.id,
        %{name: "Rumour", segments: 4, visibility: :known, filled: 3, influences: "KNOWN SECRET"},
        "dm"
      )

    {:ok, _} = Tensions.create_clock(x.c.id, x.t.id, %{name: "HIDDEN SECRET", segments: 4}, "dm")
    {:ok, tick} = Ticks.open_tick(x.c.id)
    d = dispatch(x.t)
    assert_receive {:discord, :create_public_thread, {"789", _}}
    assert d.thread_id == "9001"
    opening = Repo.one!(from i in DiscussionIntent, where: i.discussion_id == ^d.id)
    assert opening.content =~ "## Tick 1 ·"
    assert opening.content =~ "### Supply: `▰▱▱▱` 1/4"
    assert opening.content =~ "River traffic"
    assert opening.content =~ "### Rumour"
    assert opening.content =~ "### Take part\n- Discuss plans"
    assert opening.content =~ "`/intent view tick:#{tick.id}`"
    assert opening.content =~ "**Revise or withdraw until close.**"
    refute opening.content =~ "3/4"
    refute opening.content =~ "SECRET"
    assert opening.content =~ "not a confirmed commitment"
    link = Enum.find(Deliveries.list_deliveries(x.c.id), &String.contains?(&1.key, ":overview:"))
    assert link.content =~ "https://discord.com/channels/123/9001"
    draft = freeze(x.c, tick)
    assert {:ok, %{draft: approved}} = event(x.c, tick, draft, x.t)
    assert Repo.aggregate(DiscussionIntent, :count) == 1
    assert {:ok, _} = Ticks.publish_tick(x.c.id, tick.id, approved.id)
    assert Repo.aggregate(DiscussionIntent, :count) == 2
    dispatch(x.t)
    assert Repo.aggregate(Discussion, :count) == 1
    refute_receive {:discord, :create_public_thread, _}
    {:ok, next} = Ticks.open_tick(x.c.id)
    dispatch(x.t)
    assert Repo.aggregate(Discussion, :count) == 1
    refute_receive {:discord, :create_public_thread, _}

    assert Enum.any?(
             Repo.all(DiscussionIntent),
             &String.contains?(&1.content, "## Tick 2 · Battle\n\nThe crossing holds")
           )

    # Resolution's automatic pause of private pressures cannot enter a public bundle.
    draft2 = freeze(x.c, next)
    assert {:error, _} = event(x.c, next, draft2, x.t, "resolution")

    private_clocks =
      Repo.all(
        from c in AsyncWorlds.Clocks.Clock,
          where: c.campaign_id == ^x.c.id and c.visibility != :public
      )

    assert {:ok, %{draft: paused}} =
             Ticks.edit_draft(
               x.c.id,
               next.id,
               draft2.id,
               %{
                 type: "world",
                 key: "a-private",
                 event: %{
                   title: "",
                   text: "",
                   kind: "routine",
                   audience: "dm",
                   changes:
                     Enum.map(
                       private_clocks,
                       &%{entity: "clock", id: &1.id, attrs: %{paused: true}}
                     )
                 }
               },
               "456",
               "Pause private pressures separately"
             )

    assert {:ok, %{draft: settled}} = event(x.c, next, paused, x.t, "resolution")
    assert {:ok, _} = Ticks.publish_tick(x.c.id, next.id, settled.id)
    dispatch(x.t)

    assert Enum.any?(
             Repo.all(DiscussionIntent),
             &String.contains?(&1.content, "Historical — resolved")
           )

    assert Repo.get!(DiscussionIntent, opening.id).content == opening.content

    assert Enum.all?(
             Enum.filter(Deliveries.list_deliveries(x.c.id), &(&1.kind == :public)),
             &(!String.contains?(&1.content, "SECRET"))
           )

    for delivery <- Deliveries.list_deliveries(x.c.id),
        delivery.kind == :public,
        do: deliver(delivery)

    for delivery <- Deliveries.list_deliveries(x.c.id), delivery.kind == :public do
      assert Repo.get!(AsyncWorlds.Deliveries.Delivery, delivery.id).message_id == "1001"
      deliver(delivery)
    end
  end

  test "resolved conversation remains historical and linked without ongoing instructions", x do
    {:ok, tick} = Ticks.open_tick(x.c.id)
    dispatch(x.t)
    draft = freeze(x.c, tick)
    assert {:ok, %{draft: approved}} = event(x.c, tick, draft, x.t, "resolution")
    assert {:ok, _} = Ticks.publish_tick(x.c.id, tick.id, approved.id)
    assert {:error, _} = Ticks.publish_tick(x.c.id, tick.id, approved.id)
    {:ok, next} = Ticks.open_tick(x.c.id)
    dispatch(x.t)
    historical = Repo.one!(from i in DiscussionIntent, where: i.key == ^"#{next.id}:opening")
    assert historical.content =~ "Historical — resolved"
    refute historical.content =~ "Discuss plans"
    assert historical.overview =~ "historical"
    assert Repo.aggregate(Discussion, :count) == 1
  end

  test "ambiguous create is persisted before transport and requires fresh scoped recovery", x do
    {:ok, _} = Ticks.open_tick(x.c.id)
    d = Repo.get_by!(Discussion, tension_id: x.t.id)
    FakeAdapter.fail(:create_public_thread, {:error, {:ambiguous, :unknown_result}})
    assert {:cancel, :recovery_required} = OpenTensionDiscussion.run(d.id, FakeAdapter)
    assert_receive {:discord, :create_public_thread, _}
    assert Repo.get!(Discussion, d.id).status == "ambiguous"
    assert :ok = OpenTensionDiscussion.run(d.id, FakeAdapter)
    refute_receive {:discord, :create_public_thread, _}
    {:ok, expected} = TensionDiscussions.get(x.scope, x.t.id)

    assert {:error, :unauthorized} =
             TensionDiscussions.recover(
               %{x.scope | discord_user_id: "999"},
               x.t.id,
               expected,
               {:bind, "9001"},
               FakeAdapter
             )

    assert {:error, :invalid_thread} =
             TensionDiscussions.recover(x.scope, x.t.id, expected, {:bind, "nope"}, FakeAdapter)

    FakeAdapter.fail(:inspect_thread, {:ok, %{guild_id: "999", parent_id: "789", type: 11}})

    assert {:error, :invalid_thread} =
             TensionDiscussions.recover(x.scope, x.t.id, expected, {:bind, "9001"}, FakeAdapter)

    FakeAdapter.fail(:inspect_thread, nil)

    assert {:ok, bound} =
             TensionDiscussions.recover(x.scope, x.t.id, expected, {:bind, "9001"}, FakeAdapter)

    assert hd(bound.recovery["entries"])["actor"] == "456"
    assert :ok = OpenTensionDiscussion.run(d.id, FakeAdapter)

    assert {:error, :stale_recovery} =
             TensionDiscussions.recover(
               x.scope,
               x.t.id,
               bound,
               :confirm_duplicate_create,
               FakeAdapter
             )
  end

  test "rate-limit retry, interrupted create, permission denial and explicit duplicate-create confirmation",
       x do
    {:ok, _} = Ticks.open_tick(x.c.id)
    d = Repo.get_by!(Discussion, tension_id: x.t.id)
    FakeAdapter.fail(:create_public_thread, {:error, {:retryable, :rate_limited}})
    assert {:error, :retryable} = OpenTensionDiscussion.run(d.id, FakeAdapter)
    assert Repo.get!(Discussion, d.id).status == "pending"
    assert {:ok, {:create, abandoned}} = TensionDiscussions.claim(d.id)
    assert :ok = OpenTensionDiscussion.run(d.id, FakeAdapter)
    {:ok, expected} = TensionDiscussions.get(x.scope, x.t.id)
    assert expected.status == "ambiguous"

    assert {:ok, _} =
             TensionDiscussions.recover(
               x.scope,
               x.t.id,
               expected,
               :confirm_duplicate_create,
               FakeAdapter
             )

    assert {:error, :stale_attempt} = TensionDiscussions.settle(abandoned, {:ok, "8888"})
    FakeAdapter.fail(:create_public_thread, {:error, {:permanent, :forbidden}})
    assert {:cancel, :recovery_required} = OpenTensionDiscussion.run(d.id, FakeAdapter)
    assert Repo.get!(Discussion, d.id).status == "blocked"
    assert :ok = OpenTensionDiscussion.run(d.id, FakeAdapter)
  end

  test "partial message failure, deleted/archived/permission failures never replace a conversation",
       x do
    {:ok, _} = Ticks.open_tick(x.c.id)
    d = dispatch(x.t)
    deliveries = Deliveries.list_deliveries(x.c.id)
    overview = Enum.find(deliveries, &String.contains?(&1.key, ":overview:"))
    post = Enum.find(deliveries, &(&1.recipient_id == "9001"))
    deliver(overview)

    for reason <- [:not_found, :forbidden, :invalid_request] do
      FakeAdapter.fail(:send_public, {:error, {:permanent, reason}})
      current = Repo.get!(AsyncWorlds.Deliveries.Delivery, post.id)

      current =
        if current.status == :failed do
          {:ok, retried} = Deliveries.retry_delivery(x.c.id, current.id, current.generation)
          retried
        else
          current
        end

      assert {:cancel, ^reason} =
               DeliverDiscord.perform(%Oban.Job{
                 args: %{"delivery_id" => current.id, "generation" => current.generation}
               })

      assert Repo.get!(Discussion, d.id).thread_id == "9001"
      assert :ok = OpenTensionDiscussion.run(d.id, FakeAdapter)
    end

    assert Repo.get!(AsyncWorlds.Deliveries.Delivery, overview.id).status == :sent
    assert_receive {:discord, :create_public_thread, _}
    refute_receive {:discord, :create_public_thread, _}
    FakeAdapter.fail(:send_public, nil)
    current = Repo.get!(AsyncWorlds.Deliveries.Delivery, post.id)
    {:ok, retried} = Deliveries.retry_delivery(x.c.id, post.id, current.generation)
    deliver(retried)
    assert Repo.get!(AsyncWorlds.Deliveries.Delivery, post.id).status == :sent
  end

  test "archived thread is not silently unarchived; manual Discord repair and delivery retry reuse it",
       x do
    {:ok, _} = Ticks.open_tick(x.c.id)
    d = dispatch(x.t)
    post = Enum.find(Deliveries.list_deliveries(x.c.id), &(&1.recipient_id == d.thread_id))

    FakeAdapter.fail(
      :inspect_thread,
      {:ok, %{guild_id: "123", parent_id: "789", type: 11, archived: true}}
    )

    assert {:cancel, :thread_archived} =
             DeliverDiscord.perform(%Oban.Job{
               args: %{"delivery_id" => post.id, "generation" => post.generation}
             })

    refute_receive {:discord, :send_public, _}
    FakeAdapter.fail(:inspect_thread, nil)
    failed = Repo.get!(AsyncWorlds.Deliveries.Delivery, post.id)
    assert failed.last_error == "thread_archived"
    {:ok, retried} = Deliveries.retry_delivery(x.c.id, failed.id, failed.generation)
    deliver(retried)
    assert Repo.get!(Discussion, d.id).thread_id == d.thread_id
  end

  test "publication intent and job roll back with a later outbox conflict, then publish once",
       x do
    {:ok, tick} = Ticks.open_tick(x.c.id)
    draft = freeze(x.c, tick)
    assert {:ok, %{draft: approved}} = event(x.c, tick, draft, x.t)
    jobs_before = Repo.aggregate(Oban.Job, :count)

    assert {:error, :forced} =
             Repo.transaction(fn ->
               {:ok, _} =
                 Deliveries.enqueue(x.c.id, tick.id, %{
                   key: "tick:#{tick.id}:public:789:0",
                   kind: :public,
                   recipient_id: "789",
                   content: "conflict"
                 })

               assert {:error, :delivery_conflict} =
                        Ticks.publish_tick(x.c.id, tick.id, approved.id)

               Repo.rollback(:forced)
             end)

    assert Repo.aggregate(DiscussionIntent, :count) == 1
    assert Repo.aggregate(Oban.Job, :count) == jobs_before
    assert Repo.get!(AsyncWorlds.Tensions.Tension, x.t.id).description == x.t.description
    assert {:ok, _} = Ticks.publish_tick(x.c.id, tick.id, approved.id)
    assert Repo.aggregate(DiscussionIntent, :count) == 2
    assert {:error, :already_published} = Ticks.publish_tick(x.c.id, tick.id, approved.id)
    assert Repo.aggregate(DiscussionIntent, :count) == 2
  end

  test "audience changes invalidate opening preparation and frozen publication inputs", x do
    assert {:ok, prepared} = AsyncWorlds.Ticks.Opening.prepare(x.scope)
    assert {:ok, private} = Tensions.edit_tension(x.c.id, x.t.id, %{audience: :dm}, "dm", x.t)
    assert {:error, :stale_preparation} = AsyncWorlds.Ticks.Opening.open(x.scope, prepared.token)
    {:ok, tick} = Ticks.open_tick(x.c.id)
    assert Repo.aggregate(Discussion, :count) == 0
    draft = freeze(x.c, tick)
    # Simulates an unsupported writer bypassing the management lock.
    Repo.update!(Ecto.Changeset.change(private, audience: :public))
    assert {:error, :stale_live_state} = Ticks.publish_tick(x.c.id, tick.id, draft.id)
    assert Repo.aggregate(DiscussionIntent, :count) == 0
  end

  test "review audience changes publish atomically and private again stops future output without retracting history",
       x do
    {:ok, tick} = Ticks.open_tick(x.c.id)
    dispatch(x.t)
    draft = freeze(x.c, tick)

    operation = %{
      type: "world",
      key: "private",
      event: %{
        title: "Private reconsideration",
        text: "DM SECRET",
        kind: "event",
        audience: "dm",
        changes: [
          %{
            entity: "tension",
            id: x.t.id,
            attrs: %{audience: "dm", name: "Private renamed situation"}
          }
        ]
      }
    }

    public_operation = put_in(operation, [:event, :audience], "public")

    assert {:error, :invalid_edit} =
             Ticks.edit_draft(
               x.c.id,
               tick.id,
               draft.id,
               public_operation,
               "456",
               "Reject private after context"
             )

    assert {:ok, %{draft: approved}} =
             Ticks.edit_draft(x.c.id, tick.id, draft.id, operation, "456", "Change audience")

    assert Repo.get!(AsyncWorlds.Tensions.Tension, x.t.id).audience == :public
    assert {:ok, _} = Ticks.publish_tick(x.c.id, tick.id, approved.id)
    assert Repo.get!(AsyncWorlds.Tensions.Tension, x.t.id).audience == :dm
    {:ok, _} = Ticks.open_tick(x.c.id)
    assert Repo.aggregate(DiscussionIntent, :count) == 1
    historical = Repo.one!(DiscussionIntent)
    assert historical.content =~ "Battle"
    refute historical.content =~ "SECRET"
    refute historical.content =~ "Private renamed"
  end

  test "a published public Event can open a new Tension and public clock using allocated IDs",
       x do
    {:ok, tick} = Ticks.open_tick(x.c.id)
    draft = freeze(x.c, tick)

    op = %{
      type: "world",
      key: "new",
      event: %{
        title: "A new danger",
        text: "The captain needs help",
        kind: "event",
        audience: "public",
        changes: [
          %{entity: "tension", id: nil, attrs: %{name: "Captain", audience: "public"}},
          %{
            entity: "clock",
            id: nil,
            attrs: %{name: "Recovery", segments: 4, visibility: "public", tension_id: "new:new:0"}
          }
        ]
      }
    }

    assert {:ok, %{draft: approved}} =
             Ticks.edit_draft(x.c.id, tick.id, draft.id, op, "456", "Publish a new situation")

    assert Repo.aggregate(Discussion, :count) == 1
    assert {:ok, _} = Ticks.publish_tick(x.c.id, tick.id, approved.id)
    new_t = Enum.find(Tensions.list_tensions(x.c.id), &(&1.name == "Captain"))
    assert new_t.audience == :public
    new_d = Repo.get_by!(Discussion, tension_id: new_t.id)

    assert Repo.one!(from i in DiscussionIntent, where: i.discussion_id == ^new_d.id).content =~
             "The captain needs help"
  end

  test "recovery cannot attach a second Tension to an already mapped thread", x do
    {:ok, another} = Tensions.create_tension(x.c.id, %{name: "Harvest", audience: :public}, "dm")
    {:ok, _} = Ticks.open_tick(x.c.id)
    dispatch(x.t)
    d = Repo.get_by!(Discussion, tension_id: another.id)
    assert {:ok, {:create, _}} = TensionDiscussions.claim(d.id)
    assert {:ok, :skip} = TensionDiscussions.claim(d.id)
    expected = Repo.get!(Discussion, d.id)

    assert {:error, :thread_already_bound} =
             TensionDiscussions.recover(
               x.scope,
               another.id,
               expected,
               {:bind, "9001"},
               FakeAdapter
             )

    assert Repo.get!(Discussion, d.id).thread_id == nil
  end

  test "a DM-only Resolution updates public historical status without publishing its prose or private pressure",
       x do
    {:ok, _} = Tensions.create_clock(x.c.id, x.t.id, %{name: "HIDDEN SECRET", segments: 4}, "dm")
    {:ok, tick} = Ticks.open_tick(x.c.id)
    dispatch(x.t)
    draft = freeze(x.c, tick)

    op = %{
      type: "world",
      key: "settled",
      event: %{
        title: "SECRET TITLE",
        text: "SECRET TEXT",
        kind: "resolution",
        audience: "dm",
        changes: [
          %{entity: "tension", id: x.t.id, attrs: %{status: "resolved"}}
        ]
      }
    }

    assert {:ok, %{draft: approved}} =
             Ticks.edit_draft(x.c.id, tick.id, draft.id, op, "456", "Private adjudication")

    assert Repo.aggregate(DiscussionIntent, :count) == 1
    assert {:ok, _} = Ticks.publish_tick(x.c.id, tick.id, approved.id)
    dispatch(x.t)
    intents = Repo.all(DiscussionIntent)
    assert length(intents) == 2
    assert Enum.any?(intents, &String.contains?(&1.content, "Historical — resolved"))
    assert Enum.all?(intents, &(!String.contains?(&1.content, "SECRET")))
  end

  test "private defaults and foreign campaign references cannot create player intents", x do
    {:ok, other} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "124",
        dm_user_id: "457",
        public_channel_id: "790"
      })

    {:ok, foreign} =
      Tensions.create_tension(other.id, %{name: "FOREIGN", audience: :public}, "dm")

    {:ok, private} = Tensions.create_tension(x.c.id, %{name: "PRIVATE"}, "dm")
    assert private.audience == :dm
    {:ok, tick} = Ticks.open_tick(x.c.id)
    assert Repo.aggregate(Discussion, :count) == 1
    draft = freeze(x.c, tick)
    assert {:error, _} = event(x.c, tick, draft, foreign)
    assert {:error, _} = event(x.c, tick, draft, private)

    assert {:error, :not_found} =
             TensionDiscussions.get(%{campaign: other, discord_user_id: "457"}, x.t.id)

    assert Enum.all?(
             Repo.all(DiscussionIntent),
             &(!String.contains?(&1.content, ["PRIVATE", "FOREIGN"]))
           )
  end
end
