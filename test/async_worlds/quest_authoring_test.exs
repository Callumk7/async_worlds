defmodule AsyncWorlds.QuestAuthoringTest do
  use AsyncWorlds.DataCase
  import AsyncWorlds.QuestFixtures
  alias AsyncWorlds.{Campaigns, Characters, Quests, Repo, Ticks}
  alias AsyncWorlds.Quests.{Authoring, Definition, Quest, Revision, WorkingCopy}

  setup do
    {:ok, campaign} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "123",
        dm_user_id: "456",
        public_channel_id: "789"
      })

    %{campaign: campaign}
  end

  defp attrs(work), do: Map.take(work, [:name, :content_id, :definition])

  defp save(campaign, work),
    do: Quests.save_working_copy(campaign, "456", work.id, work.version, attrs(work))

  defp release(campaign, work),
    do: Quests.release_working_copy(campaign, "456", work.id, work.version, attrs(work))

  defp complete(work) do
    [node] = work.definition["nodes"]
    ending = Authoring.new_node() |> Map.merge(%{"text" => "Welcome aboard", "ending" => true})
    choice = Authoring.new_choice() |> Map.put("label", "Introduce yourself")

    choice =
      put_in(choice, ["outcomes", "fixed"], %{
        "text" => "The harbourmaster smiles",
        "next_node" => ending["id"],
        "effects" => []
      })

    %{
      work
      | name: "Meet the harbourmaster",
        content_id: "harbourmaster",
        definition: %{
          "start_node" => node["id"],
          "nodes" => [
            Map.merge(node, %{"text" => "Meet the harbourmaster", "choices" => [choice]}),
            ending
          ]
        }
    }
  end

  test "unprojectable rolled pools cannot persist and the prior draft remains reopenable", c do
    {:ok, work} = Quests.create_working_copy(c.campaign, "456")
    complete = complete(work)
    path = ["nodes", Access.at(0), "choices", Access.at(0)]
    definition = update_in(complete.definition, path, &Authoring.convert(&1, "rolled"))
    assert {:ok, saved} = save(c.campaign, %{complete | definition: definition})

    for invalid <- [%{}, [], [1]] do
      malformed = put_in(saved.definition, path ++ ["dice"], invalid)
      assert {:error, :unsupported_edit} = save(c.campaign, %{saved | definition: malformed})
      assert {:ok, ^saved} = Quests.get_working_copy(c.campaign, "456", saved.id)
      assert Authoring.form_params(saved)["node_0_choice_0_dice"] == "1"
    end

    for effect <- [
          %{"type" => "clock_delta", "clock_id" => %{}, "delta" => 1},
          %{
            "type" => "set_flag",
            "key" => "bonus",
            "flag" => %{"type" => "string", "value" => %{}, "player_visible" => false}
          }
        ] do
      malformed = put_in(saved.definition, path ++ ["critical_effects"], [effect])
      assert {:error, :unsupported_edit} = save(c.campaign, %{saved | definition: malformed})
      assert {:ok, ^saved} = Quests.get_working_copy(c.campaign, "456", saved.id)
    end
  end

  test "persistent incomplete copies are unassignable; invalid release rolls back every write; repair appends",
       c do
    {:ok, work} = Quests.create_working_copy(c.campaign, "456")
    partial = %{work | name: "Meet the harbourmaster"}
    assert {:ok, saved} = save(c.campaign, partial)
    assert {:ok, ^saved} = Quests.get_working_copy(c.campaign, "456", work.id)
    assert {:ok, %{revisions: []}} = Quests.library(c.campaign, "456")
    assert Repo.aggregate(Quest, :count) == 0

    invalid =
      complete(saved)
      |> Map.update!(
        :definition,
        &put_in(
          &1,
          ["nodes", Access.at(0), "choices", Access.at(0), "outcomes", "fixed", "next_node"],
          "missing"
        )
      )

    assert {:error, {:validation, errors}} = release(c.campaign, invalid)

    assert {"nodes[0].choices[0].outcomes.fixed.next_node", _} =
             Enum.find(errors, fn {path, _} -> String.ends_with?(path, "next_node") end)

    assert Repo.get!(WorkingCopy, saved.id) == saved
    assert Repo.aggregate(Quest, :count) == 0
    assert Repo.aggregate(Revision, :count) == 0
    assert {:ok, %{draft: draft, revision: revision}} = release(c.campaign, complete(saved))
    assert revision.number == 1
    assert draft.base_revision_id == revision.id
    assert draft.version == saved.version + 1
    assert {:error, :stale_working_copy} = release(c.campaign, complete(saved))
    assert Repo.aggregate(Revision, :count) == 1

    {:ok, character} =
      Characters.create_character(c.campaign, "456", %{name: "Rook", discord_user_id: "991"})

    assert {:error, :not_found} =
             Quests.assign(c.campaign, "456", character.id, "invalid-draft-id")

    assert {:ok, progression} = Quests.assign(c.campaign, "456", character.id, revision.id)
    {:ok, tick} = Ticks.open_tick(c.campaign.id)
    {:ok, _} = Ticks.close_tick(c.campaign.id, tick.id)
    frozen = Repo.get!(Ticks.Tick, tick.id)

    edited = %{
      draft
      | definition: put_in(draft.definition, ["nodes", Access.at(0), "text"], "A new welcome")
    }

    assert {:ok, %{revision: next}} = release(c.campaign, edited)
    assert next.number == 2
    assert Repo.get!(Revision, revision.id) == revision
    assert Repo.get!(Quests.Progression, progression.id) == progression
    assert Repo.get!(Ticks.Tick, tick.id) == frozen
    assert {:error, :tick_locked} = Quests.swap(c.campaign, "456", character.id, next.id)
  end

  test "optimistic saves/releases, old revision editors and imports cannot silently overwrite",
       c do
    {:ok, work} = Quests.create_working_copy(c.campaign, "456")
    work = complete(work)
    {:ok, saved} = save(c.campaign, work)
    assert {:error, :stale_working_copy} = save(c.campaign, %{work | name: "Lost"})
    {:ok, %{draft: draft, revision: r1}} = release(c.campaign, saved)
    {:ok, other} = Quests.create_working_copy(c.campaign, "456", r1.id)
    {:ok, %{revision: r2}} = release(c.campaign, draft)
    assert r2.number == 2
    assert {:error, :stale_base_revision} = save(c.campaign, other)
    assert {:error, :stale_base_revision} = release(c.campaign, other)
    {:ok, old} = Quests.create_working_copy(c.campaign, "456", r1.id)
    assert {:error, :stale_base_revision} = release(c.campaign, old)
    {:ok, imported_editor} = Quests.create_working_copy(c.campaign, "456", r2.id)

    doc = %{
      "version" => 1,
      "quests" => [
        %{
          "name" => "Imported rename",
          "content_id" => draft.content_id,
          "definition" => r2.definition
        }
      ]
    }

    assert {:ok, [%{action: :appended}]} =
             Quests.import_json(c.campaign, "456", Jason.encode!(doc))

    assert {:error, :stale_base_revision} = release(c.campaign, imported_editor)

    assert {:ok, recovered} =
             Quests.recover_working_copy(
               c.campaign,
               "456",
               other.id,
               attrs(%{other | name: "My unsaved text"})
             )

    assert recovered.quest_id == nil
    assert recovered.content_id != other.content_id
    assert recovered.name == "My unsaved text (recovered)"
    assert {:ok, %{revision: fork}} = release(c.campaign, recovered)
    assert fork.quest_id != r1.quest_id
  end

  test "imported rolled conditions and effects roundtrip unchanged and unsafe edits are rejected",
       c do
    d =
      definition()
      |> replace_choice(
        rolled()
        |> Map.put("conditions", [
          %{
            "type" => "character_flag",
            "key" => "ready",
            "flag_type" => "boolean",
            "value" => true
          }
        ])
      )

    doc = %{
      "version" => 1,
      "quests" => [%{"name" => "Imported", "content_id" => "imported", "definition" => d}]
    }

    {:ok, [%{revision: r}]} = Quests.import_json(c.campaign, "456", Jason.encode!(doc))
    {:ok, work} = Quests.create_working_copy(c.campaign, "456", r.id)

    applied =
      Authoring.apply_form(work, %{
        "name" => "New title",
        "node_0_text" => "New narrative",
        "node_0_choice_0_label" => "Edited roll"
      })

    original_choice = hd(hd(d["nodes"])["choices"])
    edited_choice = Map.put(original_choice, "label", "Edited roll")
    assert hd(applied.definition["nodes"])["choices"] == [edited_choice]
    assert hd(applied.definition["nodes"])["ending"] == false
    assert {:ok, %{revision: next}} = release(c.campaign, applied)
    assert hd(next.definition["nodes"])["choices"] == [edited_choice]
    {:ok, current} = Quests.create_working_copy(c.campaign, "456", next.id)

    tampered = %{
      current
      | definition:
          put_in(
            current.definition,
            ["nodes", Access.at(0), "choices", Access.at(0), "conditions"],
            []
          )
    }

    assert {:error, :unsupported_edit} = save(c.campaign, tampered)
    assert {:error, :unsupported_edit} = release(c.campaign, tampered)
    assert Repo.get!(Revision, r.id).definition == d
    # Outcome effects remain opaque even when narrative/destination controls are editable.
    {:ok, fixed} =
      Quests.create_quest(c.campaign, "456", %{name: "Fixed", content_id: "fixed"}, definition())

    {:ok, fixed_work} = Quests.create_working_copy(c.campaign, "456", fixed.id)
    assert {:ok, %{draft: fixed_draft, revision: roundtrip}} = release(c.campaign, fixed_work)
    assert roundtrip.definition == fixed.definition

    tampered = %{
      fixed_draft
      | definition:
          put_in(
            fixed_draft.definition,
            ["nodes", Access.at(0), "choices", Access.at(0), "outcomes", "fixed", "effects"],
            []
          )
    }

    assert {:error, :unsupported_edit} = save(c.campaign, tampered)
  end

  test "database-incompatible draft text is rejected without crashing or changing saved work",
       c do
    {:ok, work} = Quests.create_working_copy(c.campaign, "456")

    for invalid <- ["bad" <> <<0>>, <<255>>] do
      for edited <- [
            %{work | name: invalid},
            %{work | content_id: invalid},
            %{
              work
              | definition: put_in(work.definition, ["nodes", Access.at(0), "text"], invalid)
            },
            %{work | definition: Map.put(work.definition, "start_node", invalid)}
          ] do
        assert {:error, {:validation, [_ | _]}} = save(c.campaign, edited)
        assert {:error, {:validation, [_ | _]}} = release(c.campaign, edited)

        assert {:error, {:validation, [_ | _]}} =
                 Quests.recover_working_copy(c.campaign, "456", work.id, attrs(edited))

        assert Repo.get!(WorkingCopy, work.id) == work
        assert Repo.aggregate(Quest, :count) == 0
        assert Repo.aggregate(Revision, :count) == 0
      end
    end
  end

  test "persistence limits diagnose paths before structural rejection and never write", c do
    {:ok, work} = Quests.create_working_copy(c.campaign, "456")
    work = complete(work)
    {:ok, work} = save(c.campaign, work)

    for {path, edited} <- [
          {"name", %{work | name: String.duplicate("n", 8001)}},
          {"content_id", %{work | content_id: String.duplicate("i", 8001)}},
          {"start_node",
           %{
             work
             | definition: Map.put(work.definition, "start_node", String.duplicate("s", 101))
           }},
          {"nodes[0].text",
           %{
             work
             | definition:
                 put_in(
                   work.definition,
                   ["nodes", Access.at(0), "text"],
                   String.duplicate("t", 8001)
                 )
           }},
          {"nodes[0].choices[0].label",
           %{
             work
             | definition:
                 put_in(
                   work.definition,
                   ["nodes", Access.at(0), "choices", Access.at(0), "label"],
                   String.duplicate("l", 8001)
                 )
           }},
          {"nodes[0].choices[0].outcomes.fixed.text",
           %{
             work
             | definition:
                 put_in(
                   work.definition,
                   ["nodes", Access.at(0), "choices", Access.at(0), "outcomes", "fixed", "text"],
                   String.duplicate("t", 8001)
                 )
           }},
          {"nodes[0].choices[0].outcomes.fixed.next_node",
           %{
             work
             | definition:
                 put_in(
                   work.definition,
                   [
                     "nodes",
                     Access.at(0),
                     "choices",
                     Access.at(0),
                     "outcomes",
                     "fixed",
                     "next_node"
                   ],
                   String.duplicate("d", 101)
                 )
           }},
          {"extra.nested[0]",
           %{work | definition: Map.put(work.definition, "extra", %{"nested" => [<<255>>]})}}
        ] do
      for result <- [
            save(c.campaign, edited),
            release(c.campaign, edited),
            Quests.recover_working_copy(c.campaign, "456", work.id, attrs(edited))
          ] do
        assert {:error, {:validation, errors}} = result
        assert Enum.any?(errors, fn {field, message} -> field == path and is_binary(message) end)
      end

      assert Repo.get!(WorkingCopy, work.id) == work
      assert Repo.aggregate(WorkingCopy, :count) == 1
      assert Repo.aggregate(Quest, :count) == 0
      assert Repo.aggregate(Revision, :count) == 0
    end

    malformed = %{work | definition: Map.put(work.definition, "extra", "safe")}
    assert {:error, :unsupported_edit} = save(c.campaign, malformed)
    assert {:error, :unsupported_edit} = release(c.campaign, malformed)

    assert {:error, :unsupported_edit} =
             Quests.recover_working_copy(c.campaign, "456", work.id, attrs(malformed))

    assert Repo.get!(WorkingCopy, work.id) == work
  end

  test "duplicate library identities and forged stable IDs roll back release", c do
    {:ok, first} = Quests.create_working_copy(c.campaign, "456")
    {:ok, %{revision: released}} = release(c.campaign, complete(first))
    {:ok, duplicate} = Quests.create_working_copy(c.campaign, "456")
    assert {:error, %Ecto.Changeset{}} = release(c.campaign, complete(duplicate))
    assert Repo.get!(WorkingCopy, duplicate.id) == duplicate
    assert Repo.aggregate(Revision, :count) == 1
    {:ok, editor} = Quests.create_working_copy(c.campaign, "456", released.id)

    changed_id = %{
      editor
      | definition: put_in(editor.definition, ["nodes", Access.at(0), "id"], "forged")
    }

    assert {:error, :unsupported_edit} = save(c.campaign, changed_id)
    changed_identity = %{editor | content_id: "another_identity"}
    assert {:error, :immutable_content_id} = release(c.campaign, changed_identity)
    assert Repo.get!(WorkingCopy, editor.id) == editor
    assert Repo.aggregate(Revision, :count) == 1
  end

  test "shared diagnostics include missing texts duplicate IDs invalid references and ending inconsistencies" do
    d = definition()
    [hub, ending] = d["nodes"]

    bad = %{
      d
      | "start_node" => "unknown",
        "nodes" => [
          Map.merge(hub, %{"text" => " ", "ending" => true}),
          Map.put(ending, "id", hub["id"])
        ]
    }

    errors = Definition.errors(bad, %{})

    for path <- ["start_node", "nodes[0].text", "nodes[0].id", "nodes[1].id", "nodes[0].choices"] do
      assert Enum.any?(errors, fn {p, _} -> p == path end)
    end

    duplicate = put_in(d, ["nodes", Access.at(0), "choices", Access.at(1), "id"], "loop")

    assert Enum.any?(Definition.errors(duplicate, %{}), fn {p, _} ->
             p == "nodes[0].choices[1].id"
           end)
  end

  test "fresh DM authorization and campaign scoping cover every authoring operation", c do
    {:ok, work} = Quests.create_working_copy(c.campaign, "456")

    {:ok, other} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "124",
        dm_user_id: "457",
        public_channel_id: "790"
      })

    for result <- [
          Quests.get_working_copy(other, "457", work.id),
          Quests.save_working_copy(other, "457", work.id, 1, attrs(work)),
          Quests.release_working_copy(other, "457", work.id, 1, attrs(work)),
          Quests.recover_working_copy(other, "457", work.id, attrs(work))
        ] do
      assert result == {:error, :not_found}
    end

    assert {:error, :unauthorized} = Quests.library(c.campaign, "991")
    assert {:error, :unauthorized} = Quests.create_working_copy(c.campaign, "991")

    {:ok, r} =
      Quests.create_quest(other, "457", %{content_id: "foreign", name: "Foreign"}, definition())

    assert {:error, :not_found} = Quests.create_working_copy(c.campaign, "456", r.id)
    Repo.update!(Ecto.Changeset.change(c.campaign, dm_user_id: "999"))

    for result <- [
          Quests.get_working_copy(c.campaign, "456", work.id),
          save(c.campaign, work),
          release(c.campaign, work),
          Quests.recover_working_copy(c.campaign, "456", work.id, attrs(work))
        ] do
      assert result == {:error, :unauthorized}
    end
  end
end
