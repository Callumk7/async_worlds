defmodule AsyncWorlds.Ticks.ChronicleTest do
  use AsyncWorlds.DataCase, async: true
  alias AsyncWorlds.{Campaigns, Repo, Tensions, Ticks}
  alias AsyncWorlds.Ticks.{Chronicle, WorldResolver}

  setup do
    {:ok, c} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "123",
        dm_user_id: "456",
        public_channel_id: "789"
      })

    {:ok, battle} =
      Tensions.create_tension(c.id, %{name: "Battle in the Reach", audience: :public}, "456")

    location = Repo.insert!(%AsyncWorlds.Locations.Location{campaign_id: c.id, name: "Reach"})

    character =
      Repo.insert!(%AsyncWorlds.Characters.Character{
        campaign_id: c.id,
        name: "Captain",
        discord_user_id: "111"
      })

    faction = Repo.insert!(%AsyncWorlds.Factions.Faction{campaign_id: c.id, name: "Ash Company"})
    %{c: c, battle: battle, location: location, character: character, faction: faction}
  end

  defp close(c) do
    {:ok, t} = Ticks.open_tick(c.id)
    {:ok, %{snapshot: s}} = Ticks.close_tick(c.id, t.id)
    {:ok, p} = WorldResolver.resolve(s)
    {:ok, %{draft: d}} = Ticks.put_draft(c.id, t.id, s.revision, p)
    {t, d}
  end

  defp edit(x, t, d, key, event) do
    Ticks.edit_draft(
      x.c.id,
      t.id,
      d.id,
      %{type: "world", key: key, event: event},
      "456",
      "Account reviewed"
    )
  end

  defp event(x) do
    %{
      title: "The Ash Company holds the crossing",
      text: "Two assaults repelled; villagers escape, but the captain is wounded.",
      kind: "event",
      audience: "public",
      references: [
        %{entity: "tension", id: x.battle.id},
        %{entity: "location", id: x.location.id},
        %{entity: "character", id: x.character.id},
        %{entity: "faction", id: x.faction.id}
      ],
      follow_on: ["new:crossing:0"],
      changes: [
        %{entity: "tension", id: nil, attrs: %{name: "The wounded captain", audience: "public"}}
      ]
    }
  end

  test "one immutable account across every filter, causal navigation and Discord retrieval", x do
    assert {:ok, %{items: [], more?: false}} = Chronicle.list("123", "456", :dm)
    {t, d} = close(x.c)
    assert {:ok, %{draft: d}} = edit(x, t, d, "crossing", event(x))
    assert {:ok, %{items: []}} = Chronicle.list("123", "111", :player)
    assert {:error, :not_found} = Chronicle.fetch("123", "111", :player, t.id, "crossing")
    assert {:ok, _} = Ticks.publish_tick(x.c.id, t.id, d.id)
    {:ok, %{items: [account]}} = Chronicle.list("123", "111", :player)

    for filter <- [
          %{},
          %{"tick" => t.id},
          %{"entity" => "tension", "entity_id" => x.battle.id},
          %{"entity" => "location", "entity_id" => x.location.id},
          %{"entity" => "character", "entity_id" => x.character.id},
          %{"entity" => "faction", "entity_id" => x.faction.id}
        ] do
      assert {:ok, %{items: [^account]}} = Chronicle.list("123", "111", :player, filter)
    end

    assert length(account["references"]) == 5
    [follow] = account["follow_on"]
    assert follow["name"] == "The wounded captain"

    assert {:ok, %{items: [^account]}} =
             Chronicle.list("123", "111", :player, %{
               "entity" => "tension",
               "entity_id" => follow["id"]
             })

    assert {:ok, %{event: ^account, earlier: nil, later: nil}} =
             Chronicle.fetch("123", "111", :player, t.id, "crossing")

    Repo.update!(Ecto.Changeset.change(x.location, name: "Renamed"))
    Repo.delete!(x.faction)
    assert {:ok, %{items: [^account]}} = Chronicle.list("123", "111", :player)

    assert {:ok, content} =
             AsyncWorlds.Discord.ChronicleCommands.execute(
               {:chronicle, :show, %{"tick" => t.id, "event" => "crossing"}},
               %{campaign: x.c, user_id: "111"}
             )

    assert content =~ "The Ash Company holds the crossing"
    assert content =~ "Reach"
    assert content =~ "The wounded captain"
    refute Map.has_key?(account, "reason")
    refute Map.has_key?(account, "actor_id")
    {next_tick, next_draft} = close(x.c)

    next_event = %{
      title: "The captain recovers",
      text: "A new beginning.",
      audience: "public",
      kind: "event",
      changes: [],
      references: [%{entity: "tension", id: follow["id"]}]
    }

    assert {:ok, %{draft: next_draft}} = edit(x, next_tick, next_draft, "recovery", next_event)
    assert {:ok, _} = Ticks.publish_tick(x.c.id, next_tick.id, next_draft.id)

    assert {:ok, %{items: [recovery, ^account]}} =
             Chronicle.list("123", "111", :player, %{
               "entity" => "tension",
               "entity_id" => follow["id"]
             })

    assert {:ok, %{earlier: origin}} =
             Chronicle.fetch("123", "111", :player, next_tick.id, "recovery", %{
               "entity" => "tension",
               "entity_id" => follow["id"]
             })

    assert origin["id"] == account["id"]

    if System.get_env("ENG95_DEMO") do
      IO.puts("DEMO all six filters -> #{account["id"]}: #{account["title"]}")

      IO.puts(
        "DEMO follow-on -> #{follow["name"]} (#{follow["id"]}); recovery #{recovery["id"]} -> earlier #{origin["id"]}"
      )

      IO.puts(
        "DEMO after rename/removal: " <> Enum.map_join(account["references"], ", ", & &1["name"])
      )

      IO.puts("DEMO Discord command handler (no network):\n" <> content)
    end

    assert {:error, :not_found} = Chronicle.list("123", "999", :player)
  end

  test "bounded pages are complete and deterministic; navigation stays within visible filtered history",
       x do
    {t, d} = close(x.c)

    d =
      Enum.reduce(1..23, d, fn n, d ->
        e = %{
          title: "Account #{n}",
          text: "Narrative only",
          audience: if(n == 12, do: "dm", else: "public"),
          kind: "event",
          changes: []
        }

        {:ok, %{draft: next}} =
          edit(x, t, d, "entry-#{String.pad_leading(to_string(n), 2, "0")}", e)

        next
      end)

    assert {:ok, _} = Ticks.publish_tick(x.c.id, t.id, d.id)
    assert {:ok, first} = Chronicle.list("123", "111", :player)
    assert length(first.items) == 20 and first.more?
    assert {:ok, second} = Chronicle.list("123", "111", :player, %{"page" => 2})
    assert length(second.items) == 2 and not second.more?
    assert length(Enum.uniq_by(first.items ++ second.items, & &1["id"])) == 22
    assert {:ok, ^first} = Chronicle.list("123", "111", :player)

    assert {:ok, %{event: e, earlier: earlier, later: later}} =
             Chronicle.fetch("123", "111", :player, t.id, "entry-13")

    assert e["title"] == "Account 13"
    assert earlier["key"] == "entry-11"
    assert later["key"] == "entry-14"
    assert {:error, :not_found} = Chronicle.fetch("123", "111", :player, t.id, "entry-12")
    assert {:error, :invalid_filter} = Chronicle.list("123", "111", :player, %{"page" => 0})
    assert {:ok, %{items: []}} = Chronicle.list("123", "111", :player, %{"page" => 3})
    {t2, d2} = close(x.c)

    assert {:ok, %{draft: d2}} =
             edit(x, t2, d2, "new", %{
               title: "Later publication",
               text: "News",
               audience: "public",
               kind: "event",
               changes: []
             })

    assert {:ok, _} = Ticks.publish_tick(x.c.id, t2.id, d2.id)
    assert {:ok, ^first} = Chronicle.list("123", "111", :player, %{"through" => first.through})

    assert {:ok, ^second} =
             Chronicle.list("123", "111", :player, %{"page" => 2, "through" => first.through})

    if System.get_env("ENG95_DEMO"),
      do:
        IO.puts(
          "DEMO pagination: #{length(first.items)} + #{length(second.items)} = 22 distinct public Events; private entry-12 omitted; through=#{first.through} unchanged after next publication; earlier entry-11 / later entry-14"
        )
  end

  test "typed references reject foreign, hidden and forged context; private events never affect player pages",
       x do
    {:ok, foreign} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "321",
        dm_user_id: "456",
        public_channel_id: "789"
      })

    foreign_location =
      Repo.insert!(%AsyncWorlds.Locations.Location{campaign_id: foreign.id, name: "Foreign"})

    {:ok, hidden} = Tensions.create_tension(x.c.id, %{name: "Secret"}, "456")
    {t, d} = close(x.c)

    for ref <- [
          %{entity: "location", id: foreign_location.id},
          %{entity: "tension", id: hidden.id},
          %{entity: "clock", id: 1},
          %{entity: "location", id: x.location.id, name: "Forged"}
        ] do
      e = event(x) |> Map.put(:references, [ref])
      assert {:error, :invalid_edit} = edit(x, t, d, "crossing", e)
    end

    assert {:ok, %{draft: private}} =
             edit(
               x,
               t,
               d,
               "crossing",
               event(x)
               |> Map.put(:audience, "dm")
               |> Map.put(:references, [%{entity: "tension", id: hidden.id}])
             )

    assert {:ok, _} = Ticks.publish_tick(x.c.id, t.id, private.id)
    assert {:ok, %{items: [], more?: false}} = Chronicle.list("123", "111", :player)
    assert {:ok, %{items: []}} = Chronicle.list("321", "456", :dm)
    assert {:error, :not_found} = Chronicle.fetch("321", "456", :dm, t.id, "crossing")
    assert {:error, :unauthorized} = Chronicle.list("123", "111", :dm)
  end

  test "public mechanics exclude secret triggers and later private Tension labels", x do
    {:ok, clock} =
      Tensions.create_clock(
        x.c.id,
        x.battle.id,
        %{
          name: "Public pressure",
          segments: 6,
          visibility: :public,
          triggers: [%{type: :notify_dm, text: "SECRET TRIGGER"}]
        },
        "456"
      )

    {t, d} = close(x.c)

    e = %{
      title: "Public account",
      text: "Safe account",
      audience: "public",
      kind: "event",
      changes: [%{entity: "clock", id: clock.id, attrs: %{delta: 1}}]
    }

    assert {:ok, %{draft: d}} = edit(x, t, d, "a-public", e)

    secret = %{
      title: "SECRET TITLE",
      text: "SECRET TEXT",
      audience: "dm",
      kind: "event",
      changes: [
        %{entity: "tension", id: x.battle.id, attrs: %{name: "SECRET LATER NAME", audience: "dm"}}
      ]
    }

    assert {:ok, %{draft: d}} = edit(x, t, d, "z-private", secret)
    assert {:ok, _} = Ticks.publish_tick(x.c.id, t.id, d.id)
    assert {:ok, %{items: [account]}} = Chronicle.list("123", "111", :player)
    refute Jason.encode!(account) =~ "SECRET"
    refute Jason.encode!(account) =~ "triggers"
    assert {:ok, %{event: detail}} = Chronicle.fetch("123", "111", :player, t.id, "a-public")
    refute Jason.encode!(detail) =~ "SECRET"
    assert {:ok, %{items: dm}} = Chronicle.list("123", "456", :dm)
    assert Jason.encode!(dm) =~ "SECRET TRIGGER"
  end

  test "reference context is frozen and publication rejects rename/removal during review", x do
    {t, d} = close(x.c)
    assert {:ok, %{draft: d}} = edit(x, t, d, "crossing", event(x))
    Repo.update!(Ecto.Changeset.change(x.location, name: "Changed during review"))
    assert {:error, :stale_live_state} = Ticks.publish_tick(x.c.id, t.id, d.id)
    assert {:ok, %{items: []}} = Chronicle.list("123", "111", :player)
  end

  test "legacy Events without references are projected without modifying publication; routine changes stay underneath",
       x do
    {:ok, clock} =
      Tensions.create_clock(
        x.c.id,
        x.battle.id,
        %{name: "Public pressure", segments: 6, visibility: :public, background_rate: 1},
        "456"
      )

    {t, d} = close(x.c)

    e = %{
      title: "A legacy account",
      text: "The battle continues.",
      audience: "public",
      kind: "event",
      changes: [%{entity: "clock", id: clock.id, attrs: %{delta: 1}}]
    }

    assert {:ok, %{draft: d}} = edit(x, t, d, "legacy", e)

    routine = %{
      title: "",
      text: "",
      audience: "dm",
      kind: "routine",
      changes: [%{entity: "clock", id: clock.id, attrs: %{delta: 1}}]
    }

    assert {:ok, %{draft: d}} = edit(x, t, d, "routine", routine)
    assert {:ok, _} = Ticks.publish_tick(x.c.id, t.id, d.id)
    saved = Repo.get_by!(AsyncWorlds.Ticks.Publication, tick_id: t.id)

    assert {:ok, %{items: [account]}} =
             Chronicle.list("123", "111", :player, %{
               "entity" => "tension",
               "entity_id" => x.battle.id
             })

    assert account["title"] == "A legacy account"
    assert Enum.any?(account["references"], &(&1["name"] == "Battle in the Reach"))
    assert Repo.get!(AsyncWorlds.Ticks.Publication, saved.id).payload == saved.payload
    assert {:ok, detail} = AsyncWorlds.Ticks.History.fetch("123", "456", t.id)
    assert length(detail.sections["manual"].items) == 2
  end
end
