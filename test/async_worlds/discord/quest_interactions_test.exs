defmodule AsyncWorlds.Discord.QuestInteractionsTest do
  use AsyncWorlds.DataCase, async: false
  import AsyncWorlds.QuestFixtures
  import ExUnit.CaptureLog
  alias AsyncWorlds.{Campaigns, Characters, Quests, Ticks}
  alias AsyncWorlds.Quests.Submissions
  alias AsyncWorlds.Discord.{Commands, Dispatcher, FakeAdapter, NostrumAdapter, QuestInteractions}

  setup do
    start_supervised!({FakeAdapter, owner: self()})

    {:ok, campaign} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "123",
        dm_user_id: "456",
        public_channel_id: "789"
      })

    {:ok, character} =
      Characters.create_character(campaign, "456", %{name: "Rook", discord_user_id: "999"})

    {:ok, other} =
      Characters.create_character(campaign, "456", %{name: "Other", discord_user_id: "998"})

    {:ok, revision} =
      Quests.create_quest(campaign, "456", %{content_id: "test", name: "Test"}, definition())

    {:ok, progression} = Quests.assign(campaign, "456", character.id, revision.id)
    {:ok, _} = Quests.assign(campaign, "456", other.id, revision.id)

    %{
      campaign: campaign,
      character: character,
      revision: revision,
      progression: progression,
      opts: [adapter: FakeAdapter, guild_id: "123", application_id: "111"]
    }
  end

  defp invoke(c, data, user \\ 999, type \\ 2) do
    Dispatcher.handle(
      %{
        type: type,
        id: System.unique_integer([:positive]),
        application_id: 111,
        guild_id: 123,
        member: %{user_id: user},
        user: %{id: 998},
        token: "private-token",
        data: data
      },
      c.opts
    )
  end

  defp click(c, button, user \\ 999),
    do: invoke(c, %{custom_id: button.custom_id, component_type: 2}, user, 3)

  defp buttons(payload), do: Enum.flat_map(payload.components, & &1.components)
  defp button(payload, label), do: Enum.find(buttons(payload), &String.contains?(&1.label, label))

  test "DM personas use real independent submissions and generation-bound controls", c do
    alias AsyncWorlds.Discord.DebugSessions
    {:ok, _} = Ticks.open_tick(c.campaign.id)
    assert {:ok, _} = DebugSessions.transition("123", "456", {:player, c.character.id})
    assert {:ok, payload} = invoke(c, %{name: "quest"}, 456)
    assert payload.content =~ "Testing as Rook"
    {:ok, before_copies} = AsyncWorlds.PlayerAccess.context(c.campaign, "456")
    {:ok, _} = DebugSessions.transition("123", "456", {:messages, true})
    {:ok, after_copies} = AsyncWorlds.PlayerAccess.context(c.campaign, "456")
    assert before_copies.access == after_copies.access
    assert Enum.all?(buttons(payload), &(byte_size(&1.custom_id) <= 100))
    assert {:ok, _} = click(c, button(payload, "loop"), 456)
    assert {:ok, %{choice_id: "loop"}} = Submissions.player_state("123", "999")

    assert {:error, :unauthorized} =
             invoke(c, %{name: "tick", options: [%{type: 1, name: "status"}]}, 456)

    assert {:error, :unauthorized} =
             invoke(c, %{name: "debug", options: [%{type: 1, name: "status"}]}, 999)

    assert {:ok, status} = invoke(c, %{name: "debug", options: [%{type: 1, name: "status"}]}, 456)
    assert status.content =~ "Debug mode: player"
    assert status.content =~ "/quest"
    other = Enum.find(buttons(status), &String.contains?(&1.label, "Other"))
    assert {:ok, _} = click(c, other, 456)
    assert {:ok, second} = invoke(c, %{name: "quest"}, 456)
    assert {:ok, _} = click(c, button(second, "finish"), 456)
    assert {:ok, %{choice_id: "finish"}} = Submissions.player_state("123", "998")
    assert {:error, :stale_component} = click(c, button(payload, "finish"), 456)
    assert {:ok, _} = DebugSessions.transition("123", "456", {:player, c.character.id})
    assert {:error, :stale_component} = click(c, button(payload, "finish"), 456)
    assert {:ok, _} = invoke(c, %{name: "debug", options: [%{type: 1, name: "dm"}]}, 456)
    assert {:ok, _} = invoke(c, %{name: "tick", options: [%{type: 1, name: "status"}]}, 456)
  end

  test "accountless characters preserve player privacy and debug picker paginates", c do
    for i <- 1..16 do
      {:ok, _} = Characters.create_character(c.campaign, "456", %{name: "Test #{i}"})
    end

    {:ok, characters} = Characters.list_characters(c.campaign, "456")
    target = List.last(characters)

    {:ok, _} =
      Characters.set_flag(c.campaign, "456", target.id, "secret", %{
        "type" => "boolean",
        "value" => true,
        "player_visible" => false
      })

    assert {:ok, status} = invoke(c, %{name: "debug", options: [%{type: 1, name: "status"}]}, 456)
    assert length(status.components) <= 5
    assert {:ok, next} = click(c, button(status, "Next"), 456)
    assert next.content =~ "Page 2/2"
    assert {:ok, _} = click(c, button(next, "Test 16"), 456)
    assert {:ok, content} = invoke(c, %{name: "character"}, 456)
    assert content =~ "Testing as Test 16"
    refute content =~ "secret"
    assert {:ok, empty} = invoke(c, %{name: "quest"}, 456)
    assert empty =~ "No quest assigned"
    assert {:ok, _} = invoke(c, %{name: "debug", options: [%{type: 1, name: "off"}]}, 456)
    assert {:error, :not_found} = invoke(c, %{name: "character"}, 456)
  end

  test "debug escape remains available after the selected accountless character is deleted", c do
    alias AsyncWorlds.Discord.DebugSessions
    {:ok, character} = Characters.create_character(c.campaign, "456", %{name: "Temporary"})
    {:ok, _} = DebugSessions.transition("123", "456", {:player, character.id})
    Repo.delete!(character)
    assert {:error, :not_found} = invoke(c, %{name: "character"}, 456)
    assert {:ok, _} = invoke(c, %{name: "debug", options: [%{type: 1, name: "off"}]}, 456)
    assert {:ok, _} = invoke(c, %{name: "admin"}, 456)
  end

  test "retrieve, submit, revise and clear independently without proactive DMs", c do
    FakeAdapter.fail(:send_private, {:error, :forbidden})
    {:ok, _} = Ticks.open_tick(c.campaign.id)
    assert {:ok, :quest, :player} = Commands.route(%{name: "quest"})
    assert {:ok, :submission, :player} = Commands.route(%{name: "submission"})
    assert {:ok, payload} = invoke(c, %{name: "quest"})
    assert payload.content =~ "Hub"
    assert_receive {:discord, :defer, _}
    assert_receive {:discord, :edit_response, {_, ^payload}}
    assert {:ok, submitted} = click(c, button(payload, "loop"))
    assert submitted.content =~ "Latest choice: loop"
    assert {:ok, revised} = click(c, button(submitted, "finish"))
    assert revised.content =~ "Latest choice: finish"
    assert {:ok, own} = invoke(c, %{name: "submission"})
    assert own.content =~ "Latest choice: finish"
    assert {:ok, cleared} = click(c, button(own, "Clear"))
    assert cleared.content =~ "Latest choice: None"
    assert {:ok, %{choice_id: nil}} = Submissions.player_state("123", "999")
    refute_receive {:discord, :send_private, _}
    refute_receive {:discord, :send_public, _}
  end

  test "another player cannot use an owner's components or supplied selectors", c do
    {:ok, _} = Ticks.open_tick(c.campaign.id)
    {:ok, payload} = invoke(c, %{name: "quest"})
    {:ok, _} = click(c, button(payload, "loop"))
    assert {:error, :stale_component} = click(c, button(payload, "finish"), 998)
    assert {:error, :stale_component} = click(c, button(payload, "Clear"), 998)
    assert {:ok, %{choice_id: "loop"}} = Submissions.player_state("123", "999")
    assert {:ok, %{choice_id: nil}} = Submissions.player_state("123", "998")

    for name <- ["quest", "submission"] do
      assert {:error, :unknown_command} =
               invoke(c, %{name: name, options: [%{name: "user", value: "998"}]})

      assert {:error, :not_found} = invoke(c, %{name: name}, 997)
    end
  end

  test "old controls reject movement, reassignment and tick close with a useful private reply",
       c do
    {:ok, tick} = Ticks.open_tick(c.campaign.id)
    {:ok, original} = invoke(c, %{name: "quest"})
    {:ok, _} = Quests.swap(c.campaign, "456", c.character.id, c.revision.id)
    assert {:error, :stale_component} = click(c, button(original, "loop"))

    assert_receive {:discord, :edit_response,
                    {_,
                     "This control is no longer available. Use /quest or /submission to refresh your choices."}}

    {:ok, current} = invoke(c, %{name: "quest"})
    {:ok, %{identity: identity}} = Submissions.player_state("123", "999")
    {:ok, _} = Quests.move(c.campaign, "456", identity.progression_id, "end")
    assert {:error, :stale_component} = click(c, button(current, "loop"))
    {:ok, _} = Quests.assign(c.campaign, "456", c.character.id, c.revision.id)
    {:ok, before_close} = invoke(c, %{name: "quest"})
    {:ok, _} = Ticks.close_tick(c.campaign.id, tick.id)
    assert {:error, :stale_component} = click(c, button(before_close, "loop"))
    assert {:ok, closed} = invoke(c, %{name: "submission"})
    assert closed.content =~ "Submissions closed"
    assert closed.components == []
    refute closed.content =~ "Result"
    refute closed.content =~ "secret"
  end

  test "empty, no-tick and completed states are meaningful", c do
    assert {:ok, no_tick} = invoke(c, %{name: "quest"})
    assert no_tick.content =~ "No open tick"
    assert no_tick.components == []
    {:ok, _} = Quests.move(c.campaign, "456", c.progression.id, "end")
    assert {:ok, ending} = invoke(c, %{name: "quest"})
    assert ending.content =~ "Ending"
    assert ending.content =~ "Quest completed"
    assert ending.components == []

    {:ok, _} =
      Characters.create_character(c.campaign, "456", %{name: "New", discord_user_id: "997"})

    assert {:ok, message} = invoke(c, %{name: "submission"}, 997)
    assert message =~ "No quest assigned"
  end

  test "hidden choices and conditions never leak; current eligibility is rechecked", c do
    condition = %{
      "type" => "character_flag",
      "key" => "classified",
      "flag_type" => "boolean",
      "value" => true
    }

    disabled = choice("locked", "hub") |> Map.put("conditions", [condition])

    hidden =
      disabled
      |> Map.merge(%{
        "id" => "hidden-secret",
        "label" => "Hidden secret",
        "eligibility" => "hidden"
      })

    [hub, ending] = definition()["nodes"]

    definition =
      put_in(definition()["nodes"], [
        Map.put(hub, "choices", [choice("go", "hub"), disabled, hidden]),
        ending
      ])

    {:ok, revision} = Quests.append_revision(c.campaign, "456", c.revision.quest_id, definition)
    {:ok, _} = Quests.swap(c.campaign, "456", c.character.id, revision.id)
    {:ok, _} = Ticks.open_tick(c.campaign.id)
    {:ok, payload} = invoke(c, %{name: "quest"})
    assert button(payload, "locked").disabled
    refute inspect(payload) =~ "classified"
    refute inspect(payload) =~ "Hidden secret"
    refute inspect(payload) =~ "outcomes"
    assert {:error, :stale_component} = click(c, button(payload, "locked"))
    {:ok, _} = Characters.set_flag(c.campaign, "456", c.character.id, "classified", flag())
    {:ok, eligible} = invoke(c, %{name: "quest"})
    refute button(eligible, "locked").disabled
    {:ok, _} = Characters.clear_flag(c.campaign, "456", c.character.id, "classified")
    assert {:error, :stale_component} = click(c, button(eligible, "locked"))
    assert {:ok, %{choice_id: nil}} = Submissions.player_state("123", "999")
  end

  test "pagination preserves large Unicode content and respects all Discord limits", c do
    narrative = String.duplicate("🌍", 1900)

    choices =
      for i <- 1..32 do
        choice("choice-#{i}", "hub") |> Map.put("label", "#{i}-" <> String.duplicate("✨", 250))
      end

    [hub, ending] = definition()["nodes"]

    definition =
      put_in(definition()["nodes"], [
        hub |> Map.put("text", narrative) |> Map.put("choices", choices),
        ending
      ])

    {:ok, revision} = Quests.append_revision(c.campaign, "456", c.revision.quest_id, definition)
    {:ok, _} = Quests.swap(c.campaign, "456", c.character.id, revision.id)
    {:ok, _} = Ticks.open_tick(c.campaign.id)
    {:ok, payload} = invoke(c, %{name: "quest"})
    pages = collect_pages(c, payload, [])
    assert length(pages) > 3

    joined =
      Enum.map_join(pages, "", fn p ->
        p.content |> String.split("\n\n", parts: 2) |> List.last()
      end)

    assert joined =~ narrative
    for choice <- choices, do: assert(joined =~ choice["label"])

    for page <- pages do
      assert length(String.codepoints(page.content)) <= 2000
      assert length(page.components) <= 5
      for row <- page.components, do: assert(length(row.components) <= 5)

      for b <- buttons(page) do
        assert byte_size(b.custom_id) <= 100
        assert length(String.codepoints(b.label)) <= 80
      end

      assert NostrumAdapter.response_data(page).allowed_mentions == %{parse: []}
      assert NostrumAdapter.followup_data(page).flags == 64
    end

    last = List.last(pages)

    assert {:ok, submitted} =
             click(c, Enum.find(buttons(last), &String.starts_with?(&1.label, "32.")))

    assert submitted.content =~ "Latest choice: 32-"
  end

  defp collect_pages(c, payload, acc) do
    case button(payload, "Next") do
      nil ->
        Enum.reverse([payload | acc])

      next ->
        {:ok, page} = click(c, next)
        collect_pages(c, page, [payload | acc])
    end
  end

  test "read-only debug pages also expire across A to B to A", c do
    alias AsyncWorlds.Discord.DebugSessions
    [hub, ending] = definition()["nodes"]

    content =
      put_in(definition()["nodes"], [Map.put(hub, "text", String.duplicate("🌍", 1950)), ending])

    {:ok, revision} = Quests.append_revision(c.campaign, "456", c.revision.quest_id, content)
    {:ok, _} = Quests.swap(c.campaign, "456", c.character.id, revision.id)
    {:ok, _} = DebugSessions.transition("123", "456", {:player, c.character.id})
    {:ok, original} = invoke(c, %{name: "quest"}, 456)
    {:ok, _} = DebugSessions.transition("123", "456", {:messages, true})
    assert {:ok, _} = click(c, button(original, "Next"), 456)
    {:ok, _} = DebugSessions.transition("123", "456", {:messages, false})
    assert {:ok, _} = click(c, button(original, "Next"), 456)
    {:ok, characters} = Characters.list_characters(c.campaign, "456")
    other = Enum.find(characters, &(&1.id != c.character.id))
    {:ok, _} = DebugSessions.transition("123", "456", {:player, other.id})
    {:ok, _} = DebugSessions.transition("123", "456", {:player, c.character.id})
    assert {:error, :stale_component} = click(c, button(original, "Next"), 456)
    {:ok, _} = DebugSessions.transition("123", "456", :off)
    assert {:error, :stale_component} = click(c, button(original, "Next"), 456)
  end

  for mode <- [:no_tick, :completed, :closed] do
    @mode mode
    test "long #{@mode} quests use private read-only pages without followup bursts", c do
      narrative = String.duplicate("🌍", 1950)
      [hub, ending] = definition()["nodes"]

      content =
        put_in(definition()["nodes"], [
          Map.put(hub, "text", narrative),
          Map.put(ending, "text", narrative)
        ])

      {:ok, revision} = Quests.append_revision(c.campaign, "456", c.revision.quest_id, content)
      {:ok, progression} = Quests.swap(c.campaign, "456", c.character.id, revision.id)

      case @mode do
        :no_tick ->
          :ok

        :completed ->
          {:ok, _} = Quests.move(c.campaign, "456", progression.id, "end")

        :closed ->
          {:ok, tick} = Ticks.open_tick(c.campaign.id)
          {:ok, _} = Ticks.close_tick(c.campaign.id, tick.id)
      end

      {:ok, first} = invoke(c, %{name: "quest"})
      assert {:error, :stale_component} = click(c, button(first, "Next"), 998)
      pages = collect_pages(c, first, [])
      assert length(pages) >= 2

      joined =
        Enum.map_join(pages, "", fn p ->
          p.content |> String.split("\n\n", parts: 2) |> List.last()
        end)

      assert joined =~ narrative

      for page <- pages do
        assert length(String.codepoints(page.content)) <= 2000
        assert Enum.all?(buttons(page), &(&1.label in ["Previous", "Next"]))
        assert NostrumAdapter.response_data(page).allowed_mentions == %{parse: []}
        assert NostrumAdapter.followup_data(page).flags == 64
      end

      {:ok, back} = click(c, button(List.last(pages), "Previous"))
      assert back.content == first.content
      refute_receive {:discord, :followup_response, _}
      refute_receive {:discord, :send_public, _}
      refute_receive {:discord, :send_private, _}

      if @mode == :no_tick do
        {:ok, _} = Ticks.open_tick(c.campaign.id)
        assert {:error, :stale_component} = click(c, button(first, "Next"))
      end
    end
  end

  test "webhook creates omit empty components while edits can clear them" do
    payload = %{content: "Read-only text", components: []}
    assert NostrumAdapter.response_data(payload).components == []
    followup = NostrumAdapter.followup_data(payload)
    refute Map.has_key?(followup, :components)
    assert followup.flags == 64
    assert followup.allowed_mentions == :none
    button = %{type: 2, style: 2, custom_id: "test", label: "Next"}
    with_controls = %{payload | components: [%{type: 1, components: [button]}]}
    assert NostrumAdapter.followup_data(with_controls).components == with_controls.components
  end

  test "maximum stable identities fit and Nostrum button data routes correctly" do
    max = 9_223_372_036_854_775_807

    state = %{
      open: true,
      choice_id: nil,
      identity: %{
        tick_id: max,
        progression_id: max,
        revision_id: max,
        position_version: max,
        node_id: String.duplicate("n", 100)
      },
      quest: %{
        text: "Node",
        choices: [%{id: String.duplicate("c", 100), label: "Choice", enabled: true}]
      }
    }

    payload = QuestInteractions.present(state, 0)

    for b <- buttons(payload) do
      assert byte_size(b.custom_id) <= 100

      data = %Nostrum.Struct.ApplicationCommandInteractionData{
        custom_id: b.custom_id,
        component_type: 2
      }

      assert {:ok, {:quest_component, _, _, _}, :player} = QuestInteractions.route(data)
    end

    for data <- [
          nil,
          %{custom_id: "unknown", component_type: 2},
          %{custom_id: String.duplicate("x", 101), component_type: 2},
          %{custom_id: button(payload, "Choice").custom_id, component_type: 3}
        ] do
      assert {:error, :unknown_command} = QuestInteractions.route(data)
    end
  end

  test "malformed pages and identities fail privately without changing a submission", c do
    {:ok, _} = Ticks.open_tick(c.campaign.id)
    {:ok, payload} = invoke(c, %{name: "quest"})
    original = button(payload, "loop")
    parts = String.split(original.custom_id, ":")
    prefix = parts |> Enum.take(6) |> Enum.join(":")

    for suffix <- ["p:-1", "p:999999", "p:no", "s:forged", "c:forged"] do
      assert {:error, :stale_component} = click(c, %{custom_id: prefix <> ":" <> suffix})
    end

    assert {:ok, %{choice_id: nil}} = Submissions.player_state("123", "999")

    assert {:error, :unauthorized} =
             Dispatcher.handle(
               %{
                 type: 3,
                 id: System.unique_integer([:positive]),
                 application_id: 111,
                 guild_id: 321,
                 member: %{user_id: 999},
                 token: "private-token",
                 data: %{custom_id: original.custom_id, component_type: 2}
               },
               c.opts
             )
  end

  test "ack and response failures do not retry mutations and refresh reveals saved state", c do
    {:ok, _} = Ticks.open_tick(c.campaign.id)
    {:ok, payload} = invoke(c, %{name: "quest"})
    FakeAdapter.fail(:defer, {:error, :offline})

    capture_log(fn ->
      assert {:error, :acknowledgment_failed} = click(c, button(payload, "loop"))
    end)

    assert {:ok, %{choice_id: nil}} = Submissions.player_state("123", "999")
    FakeAdapter.fail(:defer, nil)
    FakeAdapter.fail(:edit_response, {:error, :offline})
    capture_log(fn -> assert {:error, :response_failed} = click(c, button(payload, "loop")) end)
    assert {:ok, %{choice_id: "loop"}} = Submissions.player_state("123", "999")
    FakeAdapter.fail(:edit_response, nil)
    assert {:ok, refreshed} = invoke(c, %{name: "submission"})
    assert refreshed.content =~ "Latest choice: loop"
  end
end
