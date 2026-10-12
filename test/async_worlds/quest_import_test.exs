defmodule AsyncWorlds.QuestImportTest do
  use AsyncWorlds.DataCase, async: true
  import AsyncWorlds.QuestFixtures
  alias AsyncWorlds.{Campaigns, Characters, Clocks, Quests, Repo, Ticks}
  alias AsyncWorlds.Quests.{Quest, Revision, Progression}

  setup do
    {:ok, campaign} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "123",
        dm_user_id: "456",
        public_channel_id: "789"
      })

    {:ok, other} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "124",
        dm_user_id: "457",
        public_channel_id: "790"
      })

    %{campaign: campaign, other: other}
  end

  defp document(definition \\ definition()) do
    %{
      "version" => 1,
      "quests" => [%{"content_id" => "harbor", "name" => "Harbor", "definition" => definition}]
    }
  end

  defp load(c, doc), do: Quests.import_json(c, "456", Jason.encode!(doc))

  test "invalid JSON and schema report precise paths; whole document rolls back", c do
    assert {:error, [%{path: "$", message: _}]} = Quests.import_json(c.campaign, "456", "{")

    for {doc, path} <- [
          {%{}, "$.version"},
          {Map.put(document(), "version", 2), "$.version"},
          {Map.put(document(), "resources", []), "$.resources"},
          {put_in(document(), ["quests", Access.at(0), "definition", "start_node"], "missing"),
           "$.quests[0].definition.start_node"},
          {put_in(
             document(),
             ["quests", Access.at(0), "definition", "nodes", Access.at(0), "text"],
             nil
           ), "$.quests[0].definition.nodes[0].text"}
        ] do
      assert {:error, errors} = load(c.campaign, doc)
      assert Enum.any?(errors, &(&1.path == path))
    end

    first = hd(document()["quests"])

    for second <- [first, %{first | "content_id" => "bad", "definition" => %{}}] do
      assert {:error, [_ | _]} = load(c.campaign, %{"version" => 1, "quests" => [first, second]})
      assert Repo.aggregate(Quest, :count) == 0
      assert Repo.aggregate(Revision, :count) == 0
    end
  end

  test "unchanged repeat is idempotent; changed appends while assignments and closed inputs stay pinned",
       c do
    assert {:ok, [first]} = load(c.campaign, document())
    assert first.action == :created
    assert {:ok, [repeat]} = load(c.campaign, document())
    assert repeat.action == :unchanged and repeat.revision.id == first.revision.id

    {:ok, character} =
      Characters.create_character(c.campaign, "456", %{name: "Scout", discord_user_id: "991"})

    {:ok, progression} = Quests.assign(c.campaign, "456", character.id, first.revision.id)
    {:ok, tick} = Ticks.open_tick(c.campaign.id)
    {:ok, %{snapshot: frozen}} = Ticks.close_tick(c.campaign.id, tick.id)

    changed =
      put_in(
        document(),
        ["quests", Access.at(0), "definition", "nodes", Access.at(0), "text"],
        "New harbor"
      )

    assert {:ok, [update]} = load(c.campaign, changed)
    assert update.action == :appended and update.revision.number == 2
    assert Repo.get!(Progression, progression.id) == progression
    assert Repo.get!(AsyncWorlds.Ticks.Snapshot, frozen.id) == frozen
    assert Repo.get!(Revision, first.revision.id).definition == definition()
    assert {:ok, [again]} = load(c.campaign, changed)
    assert again.revision.id == update.revision.id
  end

  test "typed condition/effect/rolled validation rejects invalid and future mechanics", c do
    {:ok, clock} = Quests.create_clock(c.campaign, "456", %{name: "Alarm", segments: 4})
    prefix = "$.quests[0].definition.nodes[0].choices[0]"
    choice = hd(hd(definition()["nodes"])["choices"])

    cases = [
      {Map.put(choice, "conditions", [
         %{"type" => "clock_threshold", "clock_id" => clock.id, "operator" => "gte", "value" => 5}
       ]), ".conditions[0].value"},
      {Map.put(choice, "conditions", [
         %{"type" => "clock_threshold", "clock_id" => 999_999, "operator" => "gte", "value" => 1}
       ]), ".conditions[0].clock_id"},
      {Map.put(choice, "conditions", [%{"type" => "resource_available", "resource_id" => "ship"}]),
       ".conditions[0].type"},
      {Map.put(choice, "conditions", [
         %{
           "type" => "character_flag",
           "key" => "token",
           "flag_type" => "boolean",
           "value" => "true"
         }
       ]), ".conditions[0].value"},
      {Map.put(choice, "dice", 2), ".dice"},
      {Map.put(rolled(), "dice", 4), ".dice"},
      {put_in(rolled(), ["critical_effects"], [%{"type" => "burn_resource"}]),
       ".critical_effects[0].type"},
      {put_in(choice, ["outcomes", "fixed", "effects"], [
         %{
           "type" => "set_flag",
           "key" => "token",
           "flag" => %{"type" => "boolean", "value" => true, "player_visible" => "yes"}
         }
       ]), ".outcomes.fixed.effects[0].flag.player_visible"}
    ]

    for {bad, suffix} <- cases do
      assert {:error, [%{path: path}]} =
               load(c.campaign, document(replace_choice(definition(), bad)))

      assert path == prefix <> suffix
      assert Repo.aggregate(Revision, :count) == 0
    end
  end

  test "duplicate node/choice IDs and cross-quest links report their exact location", c do
    doc = document()
    node = hd(definition()["nodes"])
    choice = hd(node["choices"])

    cases = [
      {put_in(doc, ["quests", Access.at(0), "definition", "nodes"], [node, node]),
       "$.quests[0].definition.nodes[1].id"},
      {put_in(doc, ["quests", Access.at(0), "definition", "nodes", Access.at(0), "choices"], [
         choice,
         choice
       ]), "$.quests[0].definition.nodes[0].choices[1].id"},
      {put_in(
         doc,
         [
           "quests",
           Access.at(0),
           "definition",
           "nodes",
           Access.at(0),
           "choices",
           Access.at(0),
           "outcomes",
           "fixed",
           "next_node"
         ],
         "another-quest-node"
       ), "$.quests[0].definition.nodes[0].choices[0].outcomes.fixed.next_node"}
    ]

    for {bad, path} <- cases do
      assert {:error, [%{path: ^path}]} = load(c.campaign, bad)
    end

    assert {:error, [%{path: "$.version"}]} =
             Quests.import_json(c.campaign, "456", ~s({"version":1,"version":1,"quests":[]}))
  end

  test "invalid later entry also rolls back changes to an existing quest", c do
    {:ok, [first]} = load(c.campaign, document())
    updated = hd(document()["quests"]) |> Map.put("name", "Renamed")
    invalid = %{updated | "content_id" => "second", "definition" => %{}}
    assert {:error, [_]} = load(c.campaign, %{"version" => 1, "quests" => [updated, invalid]})
    assert Repo.get!(Quest, first.revision.quest_id).name == "Harbor"
    assert Repo.aggregate(Revision, :count) == 1
  end

  test "sample binds clocks, runs cyclic and ending paths with controlled dice", c do
    json = File.read!("priv/quests/harbor.json")

    assert {:error,
            [
              %{
                path:
                  "$.quests[0].definition.nodes[0].choices[0].outcomes.fixed.effects[1].clock_id"
              }
            ]} = Quests.import_json(c.campaign, "456", json)

    assert {:error, :unauthorized} =
             Quests.create_clock(c.campaign, "991", %{name: "Alarm", segments: 6})

    {:ok, clock} =
      Quests.create_clock(c.campaign, "456", %{name: "Alarm", segments: 6, visibility: "hidden"})

    assert {:ok, [result]} =
             Quests.import_json(c.campaign, "456", json, clock_refs: %{"alarm" => clock.id})

    d = result.revision.definition
    state = %{node_id: "quayside", status: :active, flags: %{}, clocks: %{clock.id => clock}}
    assert {:ok, tunnel, _} = AsyncWorlds.Quests.Rules.transition(d, state, "accept-token")
    assert tunnel.node_id == "tunnel" and tunnel.clocks[clock.id].filled == 1
    assert {:ok, quay, _} = AsyncWorlds.Quests.Rules.transition(d, tunnel, "signal-crew", [4, 2])
    assert quay.node_id == "quayside"
    assert {:ok, back, _} = AsyncWorlds.Quests.Rules.transition(d, tunnel, "retreat-to-quay")
    assert back.node_id == "quayside" and back.clocks[clock.id].filled == 0

    assert {:ok, rescued, %{critical: true}} =
             AsyncWorlds.Quests.Rules.transition(d, tunnel, "signal-crew", [6, 6])

    assert rescued.status == :completed and rescued.flags["crew_trust"]["value"] == 2
    refute Map.has_key?(rescued.flags, "lantern_token")

    assert {:ok, departed, _} =
             AsyncWorlds.Quests.Rules.transition(d, tunnel, "signal-crew", [1, 3])

    assert departed.node_id == "departed" and departed.status == :completed

    {:ok, character} =
      Characters.create_character(c.campaign, "456", %{name: "Scout", discord_user_id: "991"})

    {:ok, progression} = Quests.assign(c.campaign, "456", character.id, result.revision.id)

    {:ok, veteran} =
      Characters.create_character(c.campaign, "456", %{
        name: "Veteran",
        discord_user_id: "992",
        flags: %{
          "lantern_token" => %{"type" => "boolean", "value" => true, "player_visible" => true}
        }
      })

    {:ok, veteran_progression} = Quests.assign(c.campaign, "456", veteran.id, result.revision.id)
    {:ok, _} = Quests.move(c.campaign, "456", veteran_progression.id, "tunnel")
    {:ok, tick} = Ticks.open_tick(c.campaign.id)
    {:ok, player} = AsyncWorlds.Quests.Submissions.player_state("123", "991")

    {:ok, _} =
      AsyncWorlds.Quests.Submissions.submit("123", "991", player.identity, "accept-token")

    {:ok, veteran_state} = AsyncWorlds.Quests.Submissions.player_state("123", "992")

    {:ok, _} =
      AsyncWorlds.Quests.Submissions.submit("123", "992", veteran_state.identity, "signal-crew")

    {:ok, %{snapshot: snapshot}} = Ticks.close_tick(c.campaign.id, tick.id)

    {:ok, rolls} =
      Ticks.record_quest_rolls(c.campaign.id, tick.id, snapshot.revision, fn -> 6 end)

    assert {:ok, draft} = AsyncWorlds.Ticks.WorldResolver.resolve(snapshot, %{}, rolls)
    assert hd(draft["private_results"])["outcome"] == "fixed"
    assert List.last(draft["private_results"])["critical"] == true
    assert Repo.get!(Progression, progression.id).node_id == "quayside"
    assert hd(Clocks.list_clocks(c.campaign.id)).filled == 0

    assert {:error, :tick_locked} =
             Quests.create_clock(c.campaign, "456", %{name: "Late", segments: 4})
  end

  test "name changes and historical reimports append; omitted quests are retained", c do
    original = hd(document()["quests"])
    second = %{original | "content_id" => "another", "name" => "Another quest"}

    assert {:ok, [first, retained]} =
             load(c.campaign, %{"version" => 1, "quests" => [original, second]})

    renamed = put_in(document(), ["quests", Access.at(0), "name"], "Renamed harbor")
    assert {:ok, [new_name]} = load(c.campaign, renamed)
    assert new_name.action == :appended and new_name.revision.number == 2
    assert new_name.revision.definition == first.revision.definition
    assert {:ok, [repeat]} = load(c.campaign, renamed)
    assert repeat.action == :unchanged
    assert repeat.revision.id == new_name.revision.id

    assert {:ok, [restored]} = load(c.campaign, document())
    assert restored.action == :appended and restored.revision.number == 3
    assert Repo.get!(Revision, first.revision.id) == first.revision
    assert Repo.get!(Revision, retained.revision.id) == retained.revision
    assert Repo.aggregate(Quest, :count) == 2
  end

  test "operator tasks reject repeated single-value flags before writes", c do
    import_args = ~w(--guild-id 123 --dm-user-id 456 --file priv/quests/harbor.json)

    for duplicate <- [~w(--guild-id 124), ~w(--dm-user-id 457), ~w(--file missing.json)] do
      assert_raise Mix.Error, ~r/Expected --guild-id/, fn ->
        Mix.Tasks.Quest.Import.run(import_args ++ duplicate)
      end
    end

    clock_args = ~w(--guild-id 123 --dm-user-id 456 --name Alarm --segments 6 --visibility hidden)

    for duplicate <- [
          ~w(--guild-id 124),
          ~w(--dm-user-id 457),
          ~w(--name Other),
          ~w(--segments 4),
          ~w(--visibility public)
        ] do
      assert_raise Mix.Error, ~r/Expected --guild-id/, fn ->
        Mix.Tasks.Clock.Create.run(clock_args ++ duplicate)
      end
    end

    assert_raise Mix.Error, ~r/Duplicate or invalid clock alias/, fn ->
      Mix.Tasks.Quest.Import.run(import_args ++ ~w(--clock alarm=1 --clock alarm=2))
    end

    assert Repo.aggregate(Quest, :count) == 0
    assert Clocks.list_clocks(c.campaign.id) == []
    assert Clocks.list_clocks(c.other.id) == []
  end

  test "trusted clock bootstrap rejects database-incompatible names without persistence", c do
    for name <- ["Alarm" <> <<0>>, String.duplicate("a" <> <<0xCC, 0x81>>, 150)] do
      assert {:error, :invalid_clock_name} =
               Quests.create_clock(c.campaign, "456", %{name: name, segments: 4})

      assert Clocks.list_clocks(c.campaign.id) == []
    end
  end

  test "database-incompatible strings and oversized clock references report paths", c do
    bad_name = put_in(document(), ["quests", Access.at(0), "name"], "Harbor" <> <<0>>)
    assert {:error, [%{path: "$.quests[0].name"}]} = load(c.campaign, bad_name)

    choice = hd(hd(definition()["nodes"])["choices"])

    for value <- ["unsafe" <> <<0>>, String.duplicate("x", 2001)] do
      bad =
        put_in(choice, ["outcomes", "fixed", "effects"], [
          %{
            "type" => "set_flag",
            "key" => "fact",
            "flag" => %{"type" => "string", "value" => value, "player_visible" => false}
          }
        ])

      assert {:error,
              [
                %{
                  path:
                    "$.quests[0].definition.nodes[0].choices[0].outcomes.fixed.effects[0].flag.value"
                }
              ]} =
               load(c.campaign, document(replace_choice(definition(), bad)))
    end

    bad =
      put_in(choice, ["outcomes", "fixed", "effects"], [
        %{
          "type" => "clock_delta",
          "clock_id" => 999_999_999_999_999_999_999_999_999_999_999_999,
          "delta" => 1
        }
      ])

    assert {:error,
            [
              %{
                path:
                  "$.quests[0].definition.nodes[0].choices[0].outcomes.fixed.effects[0].clock_id"
              }
            ]} =
             load(c.campaign, document(replace_choice(definition(), bad)))

    assert Repo.aggregate(Quest, :count) == 0
  end

  test "authorization uses fresh campaign, not a supplied stale DM", c do
    assert {:error, :unauthorized} = Quests.import_json(c.campaign, "991", "{")

    {:ok, _} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "123",
        dm_user_id: "999",
        public_channel_id: "789"
      })

    assert {:error, :unauthorized} = load(c.campaign, document())
    assert Repo.aggregate(Quest, :count) == 0
  end

  test "clock references are campaign scoped and resources strictly rejected", c do
    {:ok, foreign} = Clocks.create_clock(c.other.id, %{name: "Alarm", segments: 4}, "test")
    effect_path = "$.quests[0].definition.nodes[0].choices[0].outcomes.fixed.effects[0]"

    for {effect, suffix} <- [
          {%{"type" => "clock_delta", "clock_id" => foreign.id, "delta" => 1}, ".clock_id"},
          {%{"type" => "clock_delta", "clock_id" => 999_999, "delta" => 1}, ".clock_id"},
          {%{"type" => "grant_resource", "resource_id" => "ship"}, ".type"}
        ] do
      doc =
        put_in(
          document(),
          [
            "quests",
            Access.at(0),
            "definition",
            "nodes",
            Access.at(0),
            "choices",
            Access.at(0),
            "outcomes",
            "fixed",
            "effects"
          ],
          [effect]
        )

      assert {:error, errors} = load(c.campaign, doc)
      assert Enum.any?(errors, &(&1.path == effect_path <> suffix))
      assert Repo.aggregate(Quest, :count) == 0
    end
  end
end
