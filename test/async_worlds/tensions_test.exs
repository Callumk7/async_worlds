defmodule AsyncWorlds.TensionsTest do
  use AsyncWorlds.DataCase, async: true
  alias AsyncWorlds.{Campaigns, Clocks, Ticks}
  alias AsyncWorlds.DM.Tensions

  setup do
    scopes =
      for guild <- ["901", "902"] do
        {:ok, campaign} =
          Campaigns.setup_campaign(%{
            discord_guild_id: guild,
            dm_user_id: "456",
            public_channel_id: "789"
          })

        %{campaign: campaign, discord_user_id: "456"}
      end

    %{scope: hd(scopes), other: List.last(scopes)}
  end

  test "private campaign-owned situations ignore ownership/status input and authorize every operation",
       %{scope: s, other: o} do
    {:ok, t} =
      Tensions.create_tension(s, %{
        name: "Battle in the Reach",
        description: "The crossing is contested",
        campaign_id: o.campaign.id,
        status: :resolved
      })

    assert t.campaign_id == s.campaign.id
    assert t.status == :ongoing
    assert {:ok, []} = Tensions.list_tensions(o)
    assert {:error, :not_found} = Tensions.get_tension(o, t.id)
    assert {:error, :not_found} = Tensions.edit_tension(o, t.id, %{name: "Stolen"}, t)

    for id <- [
          nil,
          "bad",
          <<255>>,
          "1\0",
          -1,
          0,
          9_223_372_036_854_775_808,
          %{},
          "999999999999999999999999999"
        ] do
      assert {:error, :not_found} = Tensions.get_tension(s, id)
      assert {:error, :not_found} = Tensions.edit_tension(s, id, %{}, t)
      assert {:error, :not_found} = AsyncWorlds.DM.Clocks.get_clock(s, id)
      assert {:error, :not_found} = Tensions.list_clocks(s, id)
      assert {:error, :not_found} = Tensions.create_clock(s, id, %{name: "Missing", segments: 4})
      assert {:error, :not_found} = Tensions.associate_clock(s, id, t.id, nil)
    end

    player = %{s | discord_user_id: "999"}
    assert {:error, :unauthorized} = Tensions.list_tensions(player)
    assert {:error, :unauthorized} = Tensions.get_tension(player, t.id)
    assert {:error, :unauthorized} = Tensions.create_tension(player, %{name: "No"})
    assert {:error, :unauthorized} = Tensions.edit_tension(player, t.id, %{}, t)
    assert {:error, :unauthorized} = Tensions.list_clocks(player, t.id)

    assert {:error, :unauthorized} =
             Tensions.create_clock(player, t.id, %{name: "No", segments: 4})

    assert {:error, :not_found} = Tensions.list_clocks(o, t.id)
  end

  test "safe text and enum validation", %{scope: s} do
    for text <- ["a\0b", <<255>>, String.duplicate("x", 201)] do
      assert {:error, %Ecto.Changeset{}} = Tensions.create_tension(s, %{name: text})
    end

    for text <- ["a\0b", <<255>>, String.duplicate("x", 8001)] do
      assert {:error, %Ecto.Changeset{}} =
               Tensions.create_tension(s, %{name: "Battle", description: text})
    end

    {:ok, t} = Tensions.create_tension(s, %{name: "Battle"})

    for attrs <- [
          %{influences: <<255>>},
          %{empty_description: "a\0b"},
          %{full_description: String.duplicate("x", 8001)},
          %{mode: "other"},
          %{mode: nil},
          %{background_rate: 2_147_483_648}
        ] do
      assert {:error, %Ecto.Changeset{}} =
               Tensions.create_clock(s, t.id, Map.merge(%{name: "Balance", segments: 4}, attrs))
    end
  end

  test "multiple descriptive clocks, safe association, stale edits and immutable audits", %{
    scope: s,
    other: o
  } do
    {:ok, t} = Tensions.create_tension(s, %{name: "Battle"})
    {:ok, foreign} = Tensions.create_tension(o, %{name: "Other"})

    {:ok, balance} =
      Tensions.create_clock(s, t.id, %{
        name: "Battle balance",
        segments: 8,
        filled: 4,
        mode: :tug_of_war,
        empty_description: "Elven victory",
        full_description: "Goblin victory",
        influences: "Ash Company holds crossing",
        tension_id: foreign.id
      })

    assert balance.tension_id == t.id
    {:ok, supply} = Tensions.create_clock(s, t.id, %{name: "Supply exhaustion", segments: 6})
    {:ok, _} = Tensions.create_clock(s, t.id, %{name: "Reinforcements", segments: 4})
    assert {:ok, [^balance, ^supply, _]} = Tensions.list_clocks(s, t.id)
    assert {:error, :not_found} = Tensions.associate_clock(s, balance.id, foreign.id, balance)

    assert {:error, :unauthorized} =
             Tensions.associate_clock(%{s | discord_user_id: "999"}, balance.id, nil, balance)

    {:ok, standalone} =
      Clocks.create_clock(
        s.campaign.id,
        %{name: "Standalone", segments: 4, tension_id: t.id},
        "dm"
      )

    assert standalone.tension_id == nil
    {:ok, linked} = Tensions.associate_clock(s, standalone.id, t.id, standalone)
    assert {:error, :stale_clock} = Tensions.associate_clock(s, standalone.id, nil, standalone)
    {:ok, detached} = Tensions.associate_clock(s, linked.id, nil, linked)
    assert detached.tension_id == nil
    assert {:error, :stale_clock} = Tensions.associate_clock(s, standalone.id, t.id, standalone)
    {:ok, edited} = Tensions.edit_tension(s, t.id, %{description: "New circumstances"}, t)
    assert {:error, :stale_tension} = Tensions.edit_tension(s, t.id, %{name: "Stale"}, t)
    assert edited.description == "New circumstances"
    [creation | _] = Clocks.list_audits(s.campaign.id)
    assert creation.after["empty_description"] == "Elven victory"

    assert {:ok, _} =
             AsyncWorlds.DM.Clocks.edit_clock(
               s,
               balance.id,
               %{empty_description: "New endpoint"},
               :web,
               balance
             )

    assert hd(Clocks.list_audits(s.campaign.id)) == creation
  end

  test "private prose and hidden metadata never enter player output, known clocks remain name-only",
       %{scope: s} do
    {:ok, t} =
      Tensions.create_tension(s, %{name: "Secret situation", description: "Secret circumstances"})

    for {name, visibility} <- [{"Hidden pressure", :hidden}, {"Known pressure", :known}] do
      {:ok, _} =
        Tensions.create_clock(s, t.id, %{
          name: name,
          segments: 8,
          filled: 3,
          visibility: visibility,
          mode: :tug_of_war,
          empty_description: "Secret empty",
          full_description: "Secret full",
          influences: "Secret influence"
        })
    end

    {:ok, _} =
      Clocks.create_clock(
        s.campaign.id,
        %{name: "Standalone public", segments: 4, filled: 2},
        "dm"
      )

    {:ok, tick} = Ticks.open_tick(s.campaign.id)
    {:ok, %{snapshot: snap}} = Ticks.close_tick(s.campaign.id, tick.id)
    {:ok, payload} = Ticks.WorldResolver.resolve(snap)
    output = AsyncWorlds.Ticks.Output.render(payload, snap.data["campaign"])
    public = Enum.map_join(output["public"], "\n", & &1["content"])
    assert public =~ "Known pressure"
    assert public =~ "Standalone public: `▰▰▱▱` 2/4"
    refute public =~ "Known pressure:"

    for secret <- [
          "Hidden pressure",
          "Secret situation",
          "Secret circumstances",
          "Secret empty",
          "Secret full",
          "Secret influence"
        ] do
      refute public =~ secret
    end

    # ENG-91 freezes private adjudication context; the snapshot is DM-only.
    assert Jason.encode!(snap.data) =~ "Secret influence"
    assert snap.data["manual_world"]
  end

  test "completed clocks cannot be reassociated and status cannot be toggled", %{
    scope: s,
    other: o
  } do
    {:ok, t} = Tensions.create_tension(s, %{name: "Battle"})

    {:ok, c} =
      Tensions.create_clock(s, t.id, %{
        name: "Full",
        segments: 4,
        filled: 4,
        mode: :tug_of_war,
        empty_description: "No automatic action",
        full_description: "Still uses legacy latching",
        triggers: [%{type: :notify_dm, text: "Legacy trigger"}]
      })

    {:ok, %{clock: done, actions: [action]}} = Clocks.complete_clock(s.campaign.id, c.id, "dm")
    assert action.type == :notify_dm
    assert {:error, :completed} = Clocks.adjust_clock(s.campaign.id, c.id, -1, "dm")
    assert {:error, :completed} = Tensions.associate_clock(s, done.id, nil, done)
    assert {:error, :not_found} = Tensions.associate_clock(o, done.id, nil, done)
    assert {:error, :not_found} = Tensions.create_clock(o, t.id, %{name: "Foreign", segments: 4})
    assert {:ok, %{status: :ongoing}} = Tensions.edit_tension(s, t.id, %{status: :resolved}, t)
    # Read-only resolved presentation is ready for publication; no live API sets it.
    resolved =
      Repo.get!(AsyncWorlds.Tensions.Tension, t.id)
      |> Ecto.Changeset.change(status: :resolved)
      |> Repo.update!()

    assert {:ok, %{status: :resolved}} = Tensions.get_tension(s, resolved.id)
  end

  test "closing locks situations, descriptions and association without rewriting snapshots", %{
    scope: s
  } do
    {:ok, t} = Tensions.create_tension(s, %{name: "Battle"})
    {:ok, c} = Tensions.create_clock(s, t.id, %{name: "Balance", segments: 4})
    {:ok, tick} = Ticks.open_tick(s.campaign.id)
    {:ok, %{snapshot: snap}} = Ticks.close_tick(s.campaign.id, tick.id)
    assert {:error, :tick_locked} = Tensions.create_tension(s, %{name: "Locked"})
    assert {:error, :tick_locked} = Tensions.edit_tension(s, t.id, %{name: "Locked"}, t)
    assert {:error, :tick_locked} = Tensions.create_clock(s, t.id, %{name: "Locked", segments: 4})
    assert {:error, :tick_locked} = Tensions.associate_clock(s, c.id, nil, c)

    assert {:error, :tick_locked} =
             AsyncWorlds.DM.Clocks.edit_clock(s, c.id, %{influences: "Locked"}, :web, c)

    assert {:ok, ^snap} = Ticks.fetch_snapshot(s.campaign.id, tick.id)
  end
end
