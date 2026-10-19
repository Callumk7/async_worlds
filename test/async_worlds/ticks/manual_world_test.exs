defmodule AsyncWorlds.Ticks.ManualWorldTest do
  use AsyncWorlds.DataCase, async: true
  alias AsyncWorlds.{Campaigns, Clocks, Repo, Tensions, Ticks}
  alias AsyncWorlds.Clocks.Clock
  alias AsyncWorlds.Tensions.Tension
  alias AsyncWorlds.Ticks.{History, Publication, WorldResolver}

  defp review(c) do
    {:ok, tick} = Ticks.open_tick(c.id)
    {:ok, %{snapshot: s}} = Ticks.close_tick(c.id, tick.id)
    {:ok, p} = WorldResolver.resolve(s)
    {:ok, %{draft: d}} = Ticks.put_draft(c.id, tick.id, s.revision, p)
    {tick, s, d}
  end

  defp stage(c, tick, d, key, changes, kind \\ "event", audience \\ "dm") do
    Ticks.edit_draft(
      c.id,
      tick.id,
      d.id,
      %{
        type: "world",
        key: key,
        event: %{
          title: "The crossing holds",
          text: "The river buys another season.",
          kind: kind,
          audience: audience,
          changes: changes
        }
      },
      c.dm_user_id,
      "Considered background pressures"
    )
  end

  setup do
    {:ok, c} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "123",
        dm_user_id: "456",
        public_channel_id: "789"
      })

    {:ok, battle} =
      Tensions.create_tension(c.id, %{name: "Battle", description: "Unsettled banks"}, "dm")

    {:ok, harvest} = Tensions.create_tension(c.id, %{name: "Harvest"}, "dm")

    {:ok, clock} =
      Tensions.create_clock(
        c.id,
        battle.id,
        %{
          name: "Balance",
          segments: 4,
          filled: 2,
          background_rate: 1,
          mode: :tug_of_war,
          triggers: [%{type: :world_news, text: "MUST NOT FIRE"}]
        },
        "dm"
      )

    %{c: c, battle: battle, harvest: harvest, clock: clock}
  end

  test "two unattended ticks: bundled Event, continued pressure, Resolution, immutable history",
       x do
    {t1, s, d} = review(x.c)
    assert Enum.find(d.payload["clocks"], &(&1["id"] == x.clock.id))["filled"] == 3

    changes = [
      %{entity: "clock", id: x.clock.id, attrs: %{delta: 1, background_rate: -1}},
      %{entity: "tension", id: x.battle.id, attrs: %{description: "The crossing holds"}}
    ]

    assert {:ok, %{draft: approved}} = stage(x.c, t1, d, "crossing", changes)
    assert length(hd(approved.payload["events"])["changes"]) == 2
    assert Repo.get!(Clock, x.clock.id).filled == 2
    assert Repo.get!(Tension, x.battle.id).description == "Unsettled banks"
    assert {:error, :not_published} = Ticks.fetch_publication(x.c.id, t1.id)
    assert {:ok, %{items: []}} = History.list("123", "456")
    assert {:error, :tick_locked} = Clocks.adjust_clock(x.c.id, x.clock.id, 1, "dm")
    assert {:error, :stale_draft} = Ticks.publish_tick(x.c.id, t1.id, d.id)
    assert {:ok, reloaded} = Ticks.fetch_draft(x.c.id, t1.id)
    assert {:ok, recomputed} = WorldResolver.resolve(s, reloaded.payload["review"])
    assert recomputed == approved.payload
    assert {:ok, preview} = Ticks.preview_draft(x.c.id, t1.id, approved.id)
    refute Enum.any?(preview["public"], &String.contains?(&1["content"], "crossing"))
    assert {:ok, _} = Ticks.publish_tick(x.c.id, t1.id, approved.id)
    assert Repo.get!(Clock, x.clock.id).filled == 4
    assert Repo.get!(Clock, x.clock.id).background_rate == -1

    {t2, _, d2} = review(x.c)

    assert {:ok, %{draft: settled}} =
             stage(
               x.c,
               t2,
               d2,
               "settlement",
               [
                 %{entity: "tension", id: x.harvest.id, attrs: %{status: "resolved"}}
               ],
               "resolution"
             )

    assert {:ok, _} = Ticks.publish_tick(x.c.id, t2.id, settled.id)
    assert Repo.get!(Clock, x.clock.id).filled == 3
    assert Repo.get!(Tension, x.battle.id).status == :ongoing
    assert Repo.get!(Tension, x.harvest.id).status == :resolved
    {:ok, current} = Tensions.get_tension(x.c.id, x.battle.id)
    assert {:ok, _} = Tensions.edit_tension(x.c.id, current.id, %{name: "Renamed"}, "dm", current)
    assert {:ok, [event]} = History.tension("123", "456", x.battle.id)
    assert Enum.find(event["changes"], &(&1["entity"] == "tension"))["before"]["name"] == "Battle"
    assert {:error, :unauthorized} = History.tension("123", "player", x.battle.id)
    assert Repo.aggregate(Publication, :count) == 2
  end

  test "routine signed intentions replace rather than double apply and survive unrelated edits",
       x do
    {t, s, d} = review(x.c)

    op = %{
      type: "world",
      key: "routine",
      event: %{
        title: "",
        text: "",
        kind: "routine",
        audience: "dm",
        changes: [
          %{
            entity: "clock",
            id: x.clock.id,
            attrs: %{delta: -2, background_rate: -1, influences: "Retreating supply lines"}
          }
        ]
      }
    }

    assert {:ok, %{draft: one}} =
             Ticks.edit_draft(x.c.id, t.id, d.id, op, "456", "Routine pressure")

    assert {:ok, %{draft: two}} =
             Ticks.edit_draft(x.c.id, t.id, one.id, op, "456", "Replace same intention")

    assert hd(two.payload["clocks"])["filled"] == 1
    assert two.payload["events"] == []

    assert {:ok, %{draft: three}} =
             Ticks.edit_draft(
               x.c.id,
               t.id,
               two.id,
               %{type: "world_news", text: ["A new season"]},
               "456",
               "Narration"
             )

    assert hd(three.payload["clocks"])["filled"] == 1
    assert {:ok, recomputed} = WorldResolver.resolve(s, three.payload["review"])
    assert recomputed == three.payload
    assert {:error, :stale_draft} = Ticks.edit_draft(x.c.id, t.id, two.id, op, "456", "Stale tab")
    assert {:ok, _} = Ticks.publish_tick(x.c.id, t.id, three.id)
    assert {:ok, detail} = History.fetch("123", "456", t.id)

    assert [%{"after" => %{"influences" => "Retreating supply lines"}}] =
             detail.sections["manual"].items

    assert Repo.get!(Clock, x.clock.id).background_rate == -1
  end

  test "legacy snapshots keep full latching and reject new manual intentions", x do
    {_, s, _} = review(x.c)
    clocks = Enum.map(s.data["clocks"], &Map.put(&1, "filled", &1["segments"]))

    legacy = %{
      s
      | data:
          s.data
          |> Map.delete("manual_world")
          |> Map.delete("tensions")
          |> Map.put("clocks", clocks)
    }

    assert {:ok, payload} = WorldResolver.resolve(legacy)
    assert hd(payload["clocks"])["completed"]
    assert payload["world_news"] == ["MUST NOT FIRE"]
    assert {:error, _} = WorldResolver.resolve(legacy, %{"world" => %{"x" => %{}}})
  end

  test "Tension races prompt adjudication rather than using either clock ID", x do
    {:ok, other} =
      Clocks.create_clock(
        x.c.id,
        %{name: "Other pressure", segments: 4, filled: 3, background_rate: 1},
        "dm"
      )

    {:ok, _} = Clocks.pair_clocks(x.c.id, x.clock.id, other.id, "dm")
    {t, _, d} = review(x.c)
    assert d.payload["race_winners"] == []
    assert Enum.all?(d.payload["clocks"], &(not &1["completed"]))

    assert {:ok, %{draft: moved}} =
             stage(x.c, t, d, "adjudicate", [
               %{entity: "clock", id: x.clock.id, attrs: %{delta: 1}}
             ])

    assert moved.payload["race_winners"] == []
    assert moved.payload["trigger_results"] == []
  end

  test "resolution pauses its pressures as part of the approved bundle", x do
    {t, _, d} = review(x.c)

    assert {:ok, %{draft: resolved}} =
             stage(
               x.c,
               t,
               d,
               "peace",
               [%{entity: "tension", id: x.battle.id, attrs: %{status: "resolved"}}],
               "resolution"
             )

    assert length(hd(resolved.payload["events"])["changes"]) == 2
    refute Repo.get!(Clock, x.clock.id).paused
    assert {:ok, _} = Ticks.publish_tick(x.c.id, t.id, resolved.id)
    assert Repo.get!(Clock, x.clock.id).paused
    {_, _, next} = review(x.c)
    assert hd(next.payload["clocks"])["filled"] == 3
  end

  test "endpoints prompt adjudication, can recede, never trigger or choose a winner", x do
    {t, _, d} = review(x.c)

    assert {:ok, %{draft: full}} =
             stage(x.c, t, d, "endpoint", [%{entity: "clock", id: x.clock.id, attrs: %{delta: 1}}])

    assert [%{"endpoint" => "full"}] = full.payload["endpoint_prompts"]
    refute hd(full.payload["clocks"])["completed"]
    assert full.payload["world_news"] == []
    assert full.payload["race_winners"] == []
    assert {:ok, _} = Ticks.publish_tick(x.c.id, t.id, full.id)
    {t2, _, d2} = review(x.c)
    refute hd(d2.payload["clocks"])["completed"]

    assert {:ok, %{draft: receded}} =
             stage(x.c, t2, d2, "recede", [
               %{entity: "clock", id: x.clock.id, attrs: %{delta: -4}}
             ])

    assert [%{"endpoint" => "empty"}] = receded.payload["endpoint_prompts"]
    assert receded.payload["trigger_results"] == []
  end

  test "manual targets and history stay campaign-scoped, with fresh DM authorization", x do
    {:ok, other} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "321",
        dm_user_id: "456",
        public_channel_id: "789"
      })

    {:ok, foreign} = Tensions.create_tension(other.id, %{name: "Foreign secret"}, "dm")
    {t, _, d} = review(x.c)

    assert {:error, :invalid_edit} =
             stage(x.c, t, d, "foreign", [
               %{entity: "tension", id: foreign.id, attrs: %{description: "Cross-campaign"}}
             ])

    op = %{
      type: "world",
      key: "narrative",
      event: %{title: "No access", text: "Private", kind: "event", audience: "dm", changes: []}
    }

    scope = %{campaign: x.c, discord_user_id: "999"}

    assert {:error, :unauthorized} =
             AsyncWorlds.DM.Ticks.edit_draft(scope, t.id, d.id, op, "Unauthorized")

    assert {:error, :not_found} = History.fetch("321", "456", t.id)
    assert {:ok, []} = History.tension("321", "456", x.battle.id)

    assert {:ok, %{draft: staged}} =
             stage(x.c, t, d, "reviewed", [
               %{
                 entity: "tension",
                 id: x.battle.id,
                 attrs: %{description: "Approved circumstances"}
               }
             ])

    Repo.update!(Ecto.Changeset.change(x.battle, description: "Unapproved live edit"))
    assert {:error, :stale_live_state} = Ticks.publish_tick(x.c.id, t.id, staged.id)
    assert Repo.aggregate(Publication, :count) == 0
  end

  test "public prose cannot bundle private references; foreign entities rejected", x do
    {t, _, d} = review(x.c)

    assert {:error, :invalid_edit} =
             stage(
               x.c,
               t,
               d,
               "leak",
               [%{entity: "tension", id: x.battle.id, attrs: %{description: "Secret"}}],
               "event",
               "public"
             )

    assert {:error, :invalid_edit} =
             stage(x.c, t, d, "foreign", [%{entity: "clock", id: 999_999, attrs: %{delta: 1}}])

    assert {:ok, %{draft: narrative}} = stage(x.c, t, d, "news", [], "event", "public")
    assert {:ok, preview} = Ticks.preview_draft(x.c.id, t.id, narrative.id)
    assert Enum.any?(preview["public"], &String.contains?(&1["content"], "The crossing holds"))
  end

  test "creation/configuration and rollback/retry leave no duplicate state or Events", x do
    {t, _, d} = review(x.c)

    changes = [
      %{entity: "tension", id: nil, attrs: %{name: "Captain wounded"}},
      %{
        entity: "clock",
        id: nil,
        attrs: %{
          name: "Recovery",
          segments: 6,
          background_rate: 1,
          visibility: "hidden",
          tension_id: "new:create:0"
        }
      }
    ]

    assert {:ok, %{draft: staged}} = stage(x.c, t, d, "create", changes)

    assert {:error, :forced} =
             Repo.transaction(fn ->
               {:ok, _} =
                 AsyncWorlds.Deliveries.enqueue(x.c.id, t.id, %{
                   key: "tick:#{t.id}:public:789:0",
                   kind: :public,
                   recipient_id: "789",
                   content: "Conflicting intent"
                 })

               assert {:error, :delivery_conflict} = Ticks.publish_tick(x.c.id, t.id, staged.id)
               Repo.rollback(:forced)
             end)

    assert Repo.aggregate(Publication, :count) == 0
    assert length(Tensions.list_tensions(x.c.id)) == 2
    assert Repo.get!(Clock, x.clock.id).filled == 2
    assert {:ok, _} = Ticks.publish_tick(x.c.id, t.id, staged.id)
    assert length(Tensions.list_tensions(x.c.id)) == 3
    assert length(Clocks.list_clocks(x.c.id)) == 2
    assert {:error, :already_published} = Ticks.publish_tick(x.c.id, t.id, staged.id)
    assert Repo.aggregate(Publication, :count) == 1
  end
end
