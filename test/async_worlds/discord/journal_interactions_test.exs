defmodule AsyncWorlds.Discord.JournalInteractionsTest do
  alias AsyncWorlds.Discord.JournalCreation
  use AsyncWorlds.DataCase, async: false
  import ExUnit.CaptureLog
  alias AsyncWorlds.{Campaigns, Characters, Deliveries, Journals}
  alias AsyncWorlds.Journals.{CreationReceipt, Entry}

  alias AsyncWorlds.Discord.{
    Commands,
    DebugSessions,
    Dispatcher,
    FakeAdapter,
    JournalInteractions,
    NostrumAdapter
  }

  setup do
    start_supervised!({FakeAdapter, owner: self()})

    {:ok, campaign} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "123",
        dm_user_id: "456",
        public_channel_id: "789"
      })

    {:ok, character} =
      Characters.create_character(campaign, "456", %{name: "Explorer", discord_user_id: "999"})

    {:ok, _} =
      Characters.create_character(campaign, "456", %{name: "Other", discord_user_id: "777"})

    %{
      campaign: campaign,
      character: character,
      opts: [adapter: FakeAdapter, guild_id: "123", application_id: "111"]
    }
  end

  defp event(type, data, user \\ "999") do
    Nostrum.Struct.Interaction.to_struct(%{
      id: to_string(System.unique_integer([:positive])),
      application_id: "111",
      type: type,
      guild_id: "123",
      member: %{user: %{id: user, username: "player"}},
      token: "secret-interaction-token",
      data: data
    })
  end

  defp command(name, options \\ [], user \\ "999"),
    do:
      event(
        2,
        %{name: "journal", type: 1, options: [%{type: 1, name: name, options: options}]},
        user
      )

  defp option(name, value), do: %{type: 3, name: name, value: value}
  defp click(id, user \\ "999"), do: event(3, %{component_type: 2, custom_id: id}, user)

  defp submit(modal, title \\ "A discovery 🌍", body \\ "First line\nSecond line 🧭", user \\ "999") do
    event(
      5,
      %{
        custom_id: modal.custom_id,
        components: [
          %{type: 1, components: [%{type: 4, custom_id: "title", value: title}]},
          %{type: 1, components: [%{type: 4, custom_id: "body", value: body}]}
        ]
      },
      user
    )
  end

  defp button(payload, label) do
    payload.components
    |> Enum.flat_map(& &1.components)
    |> Enum.find(&(&1.label == label))
    |> Map.fetch!(:custom_id)
  end

  defp write(c, visibility \\ "private", user \\ "999") do
    assert {:ok, payload} =
             Dispatcher.handle(command("new", [option("visibility", visibility)], user), c.opts)

    assert_receive {:discord, :defer, _}
    assert_receive {:discord, :edit_response, _}
    id = button(payload, "Write entry")
    assert byte_size(id) <= 100
    assert {:ok, :modal_opened} = Dispatcher.handle(click(id, user), c.opts)
    assert_receive {:discord, :open_modal, {_, modal}}
    refute_receive {:discord, :defer, _}
    assert NostrumAdapter.modal_response(modal) == %{type: 9, data: modal}
    modal
  end

  defp save(c, visibility \\ "private") do
    modal = write(c, visibility)
    assert {:ok, message} = Dispatcher.handle(submit(modal), c.opts)
    assert message =~ "Saved entry #"
    assert_receive {:discord, :defer, _}
    assert_receive {:discord, :edit_response, _}
    Repo.one!(Entry)
  end

  test "converted gateway flow persists and list/open/cancel/confirm works privately", c do
    entry = save(c)
    assert {:ok, page} = Dispatcher.handle(command("list"), c.opts)
    assert_receive {:discord, :defer, _}
    assert_receive {:discord, :edit_response, _}
    assert {:ok, opened} = Dispatcher.handle(click(button(page, "Open ##{entry.id}")), c.opts)
    assert opened.content =~ "A discovery 🌍"
    assert opened.content =~ "First line\nSecond line 🧭"
    assert {:ok, prompt} = Dispatcher.handle(click(button(opened, "Delete ##{entry.id}")), c.opts)
    assert Repo.get!(Entry, entry.id)
    assert {:ok, _} = Dispatcher.handle(click(button(prompt, "Cancel")), c.opts)
    assert Repo.get!(Entry, entry.id)
    confirm = button(prompt, "Confirm deletion")
    assert {:ok, _} = Dispatcher.handle(click(confirm), c.opts)
    assert {:ok, _} = Dispatcher.handle(click(confirm), c.opts)
    assert Repo.get(Entry, entry.id) == nil
    assert Repo.one!(CreationReceipt).state == :deleted
    assert Deliveries.list_deliveries(c.campaign.id) == []
    refute_receive {:discord, :send_public, _}
    refute_receive {:discord, :send_private, _}
  end

  test "public long Unicode body is complete across private chunks and suppresses mentions", c do
    modal = write(c, "public")
    body = "@everyone\n" <> String.duplicate("🌍", 3990)
    assert {:ok, _} = Dispatcher.handle(submit(modal, "Title", body), c.opts)
    assert_receive {:discord, :defer, _}
    assert_receive {:discord, :edit_response, _}
    entry = Repo.one!(Entry)

    assert {:ok, opened} =
             Dispatcher.handle(
               command("open", [option("entry", to_string(entry.id))], "777"),
               c.opts
             )

    assert_receive {:discord, :defer, _}
    [first | rest] = AsyncWorlds.Discord.Content.formatted_chunks(opened.content)
    assert_receive {:discord, :edit_response, {_, %{content: ^first}}}

    for chunk <- rest do
      assert_receive {:discord, :followup_response, {_, %{content: ^chunk}}}
    end

    assert Enum.join([first | rest]) == opened.content
    assert String.ends_with?(opened.content, body)
    assert opened.components == []

    for chunk <- [first | rest] do
      assert byte_size(:unicode.characters_to_binary(chunk, :utf8, {:utf16, :big})) <= 3800
      assert NostrumAdapter.response_data(chunk).allowed_mentions == %{parse: []}
      assert NostrumAdapter.followup_data(chunk).flags == 64
    end

    refute_receive {:discord, :send_public, _}
  end

  test "catalogue is unconditional; typed choices and inappropriate selectors fail closed" do
    assert Enum.any?(Commands.definitions(), &(&1.name == "journal"))
    assert {:ok, {:journal_new, "private"}, :player} = Commands.route(command("new").data)
    assert {:ok, {:journal_list, :mine, nil, nil}, :player} = Commands.route(command("list").data)

    assert {:ok, {:journal_list, :character, "1", nil}, :dm} =
             Commands.route(
               command("list", [option("scope", "character"), option("character", "1")]).data
             )

    for {name, opts} <- [
          {"new", [option("visibility", "hidden")]},
          {"new", [option("character", "1")]},
          {"list", [option("character", "1")]},
          {"list", [option("scope", "character")]},
          {"list", [option("scope", "public"), option("character", "1")]},
          {"new", [option("visibility", "private"), option("visibility", "public")]}
        ] do
      assert {:error, :unknown_command} = Commands.route(command(name, opts).data)
    end
  end

  test "another player, missing/foreign/deleted IDs and forged controls do not leak private metadata",
       c do
    entry = save(c)
    assert {:ok, page} = Dispatcher.handle(command("list"), c.opts)
    open = button(page, "Open ##{entry.id}")
    assert {:error, :stale_component} = Dispatcher.handle(click(open, "777"), c.opts)
    assert {:error, :stale_component} = Dispatcher.handle(click(open <> "tampered"), c.opts)

    for id <- [to_string(entry.id), "9223372036854775807", "-1", "invalid"] do
      assert {:error, _} =
               Dispatcher.handle(command("open", [option("entry", id)], "777"), c.opts)

      assert_receive {:discord, :edit_response, _}
    end

    assert {:error, :unauthorized} =
             Dispatcher.handle(
               command(
                 "list",
                 [option("scope", "character"), option("character", to_string(c.character.id))],
                 "777"
               ),
               c.opts
             )
  end

  test "creation locator cannot be used by another actor and ownership/config/persona changes invalidate it",
       c do
    modal = write(c)

    assert {:error, :stale_component} =
             Dispatcher.handle(submit(modal, "Stolen", "Body", "777"), c.opts)

    {:ok, _} =
      Characters.update_character(c.campaign, "456", c.character.id, %{discord_user_id: "888"})

    assert {:error, :not_found} = Dispatcher.handle(submit(modal), c.opts)

    assert {:error, :stale_component} =
             Dispatcher.handle(submit(modal, "Title", "Body", "888"), c.opts)

    for _ <- 1..3 do
      assert_receive {:discord, :defer, _}
      assert_receive {:discord, :edit_response, _}
    end

    {:ok, accountless} = Characters.create_character(c.campaign, "456", %{name: "Accountless"})
    {:ok, _} = DebugSessions.transition("123", "456", {:player, accountless.id})
    modal = write(c, "private", "456")
    assert {:ok, result} = Dispatcher.handle(submit(modal, "Title", "Body", "456"), c.opts)
    assert result =~ "Testing as Accountless"
    entry = Repo.one!(Entry)
    assert entry.origin == :dm_persona
    assert entry.author_discord_user_id == "456"
    {:ok, _} = DebugSessions.transition("123", "456", :dm)
    {:ok, _} = DebugSessions.transition("123", "456", {:player, accountless.id})

    assert {:error, :stale_component} =
             Dispatcher.handle(submit(modal, "Title", "Body", "456"), c.opts)
  end

  test "input shape and Unicode boundaries fail closed, preserving exact formatting" do
    valid = fn title, body ->
      [
        %{type: 1, components: [%{type: 4, custom_id: "title", value: title}]},
        %{type: 1, components: [%{type: 4, custom_id: "body", value: body}]}
      ]
    end

    for {title, body} <- [
          {" ", "Body"},
          {"Title", "\n"},
          {String.duplicate("🌍", 101), "Body"},
          {"Title", String.duplicate("x", 4001)},
          {"Title", "NUL" <> <<0>>}
        ] do
      assert {:error, :invalid_journal_input} = JournalInteractions.inputs(valid.(title, body))
    end

    assert {:ok, %{title: "🌍", body: "\nBody\n"}} =
             JournalInteractions.inputs(valid.("🌍", "\nBody\n"))

    assert {:ok, _} =
             JournalInteractions.inputs(
               valid.(String.duplicate("🌍", 100), String.duplicate("🌍", 4000))
             )

    [row, _] = valid.("Title", "Body")

    for shape <- [
          nil,
          [],
          [row],
          [row, row],
          [%{type: 18, component: hd(row.components)}, row],
          [row, %{type: 1, components: [%{type: 4, custom_id: "unknown", value: "x"}]}]
        ] do
      assert {:error, :invalid_journal_input} = JournalInteractions.inputs(shape)
    end
  end

  test "acknowledgment failure prevents writes, ambiguous modal callback never acknowledges again",
       c do
    assert {:ok, payload} = Dispatcher.handle(command("new"), c.opts)
    assert_receive {:discord, :defer, _}
    assert_receive {:discord, :edit_response, _}
    FakeAdapter.fail(:open_modal, {:error, "secret-interaction-token"})

    log =
      capture_log(fn ->
        assert {:error, :acknowledgment_failed} =
                 Dispatcher.handle(click(button(payload, "Write entry")), c.opts)
      end)

    assert_receive {:discord, :open_modal, _}
    refute_receive {:discord, :defer, _}
    refute log =~ "secret-interaction-token"
    FakeAdapter.fail(:open_modal, nil)
    assert {:ok, :modal_opened} = Dispatcher.handle(click(button(payload, "Write entry")), c.opts)
    assert_receive {:discord, :open_modal, {_, modal}}
    FakeAdapter.fail(:defer, {:error, :offline})

    capture_log(fn ->
      assert {:error, :acknowledgment_failed} = Dispatcher.handle(submit(modal), c.opts)
    end)

    assert Repo.aggregate(Entry, :count) == 0
    assert Repo.one!(CreationReceipt).state == :pending
  end

  test "failed final response commits exactly once; different submission ID and replay after deletion are safe",
       c do
    modal = write(c)
    FakeAdapter.fail(:edit_response, {:error, :offline})

    capture_log(fn ->
      assert {:error, :response_failed} = Dispatcher.handle(submit(modal), c.opts)
    end)

    assert Repo.aggregate(Entry, :count) == 1
    FakeAdapter.fail(:edit_response, nil)
    assert {:ok, _} = Dispatcher.handle(submit(modal, "Different", "Ignored"), c.opts)
    entry = Repo.one!(Entry)
    assert entry.title == "A discovery 🌍"
    {:ok, context} = AsyncWorlds.PlayerAccess.context(c.campaign, "999")
    {:ok, target} = Journals.prepare_delete(context, entry.id)
    {:ok, :deleted} = Journals.delete_entry(context, entry.id, target.binding)
    assert {:ok, result} = Dispatcher.handle(submit(modal), c.opts)
    assert result =~ "already created and deleted"
    assert Repo.aggregate(Entry, :count) == 0
  end

  test "spent queue budget fails privately without attempting a modal", c do
    assert {:ok, payload} = Dispatcher.handle(command("new"), c.opts)
    assert_receive {:discord, :defer, _}
    assert_receive {:discord, :edit_response, _}
    opts = Keyword.put(c.opts, :modal_deadline, System.monotonic_time(:millisecond) - 1)

    assert {:error, :modal_deadline} =
             Dispatcher.handle(click(button(payload, "Write entry")), opts)

    assert_receive {:discord, :defer, _}
    assert_receive {:discord, :edit_response, _}
    refute_receive {:discord, :open_modal, _}
  end

  test "supervised consumer processes a real Nostrum-converted submission without gateway", c do
    modal = write(c)
    start_supervised!(Nostrum.ConsumerGroup)
    start_supervised!({Task.Supervisor, name: AsyncWorlds.Discord.Tasks, max_children: 100})

    consumer =
      start_supervised!({AsyncWorlds.Discord.Consumer, name: AsyncWorlds.Discord.Consumer})

    previous = Application.fetch_env!(:async_worlds, :discord)
    Application.put_env(:async_worlds, :discord, c.opts)
    on_exit(fn -> Application.put_env(:async_worlds, :discord, previous) end)
    Nostrum.ConsumerGroup.dispatch({:INTERACTION_CREATE, submit(modal), nil})
    _ = :sys.get_state(consumer)
    assert_receive {:discord, :defer, _}
    assert_receive {:discord, :edit_response, {_, result}}
    assert result =~ "Saved entry #"
    assert Repo.one!(Entry).body == "First line\nSecond line 🧭"
    assert Process.whereis(Nostrum.Supervisor) == nil
  end

  test "bounded list navigation and DM character inspection work through authenticated controls",
       c do
    {:ok, context} = AsyncWorlds.PlayerAccess.context(c.campaign, "999")

    entries =
      for _ <- 1..25 do
        {:ok, flow} = JournalCreation.begin_creation(context, System.unique_integer([:positive]))

        {:ok, result} =
          JournalCreation.submit(context, flow.id, %{title: "Repeated title", body: "Not in list"})

        result.entry_id
      end

    assert {:ok, first} = Dispatcher.handle(command("list"), c.opts)
    assert length(first.components |> Enum.flat_map(& &1.components)) == 11
    refute first.content =~ "Not in list"
    assert {:ok, second} = Dispatcher.handle(click(button(first, "Next")), c.opts)
    assert {:ok, third} = Dispatcher.handle(click(button(second, "Next")), c.opts)
    assert length(third.components |> Enum.flat_map(& &1.components)) == 6
    assert {:ok, back} = Dispatcher.handle(click(button(third, "Previous")), c.opts)
    assert back.content == second.content

    for page <- [first, second, third, back], row <- page.components, control <- row.components do
      assert byte_size(control.custom_id) <= 100
      assert length(row.components) <= 5
      assert length(page.components) <= 5
    end

    assert {:ok, inspected} =
             Dispatcher.handle(
               command(
                 "list",
                 [option("scope", "character"), option("character", to_string(c.character.id))],
                 "456"
               ),
               c.opts
             )

    assert {:ok, dm_opened} =
             Dispatcher.handle(
               click(button(inspected, "Open ##{List.last(entries)}"), "456"),
               c.opts
             )

    assert dm_opened.content =~ "Not in list"
    {:ok, _} = DebugSessions.transition("123", "456", {:player, c.character.id})

    assert {:error, :stale_component} =
             Dispatcher.handle(click(button(inspected, "Next"), "456"), c.opts)
  end

  test "confirmations recheck ownership and persona after the prompt is shown", c do
    entry = save(c)

    assert {:ok, prompt} =
             Dispatcher.handle(command("delete", [option("entry", to_string(entry.id))]), c.opts)

    {:ok, _} =
      Characters.update_character(c.campaign, "456", c.character.id, %{discord_user_id: "888"})

    assert {:error, :stale_component} =
             Dispatcher.handle(click(button(prompt, "Confirm deletion"), "888"), c.opts)

    assert Repo.get!(Entry, entry.id)

    assert {:ok, dm_prompt} =
             Dispatcher.handle(
               command("delete", [option("entry", to_string(entry.id))], "456"),
               c.opts
             )

    {:ok, _} = DebugSessions.transition("123", "456", {:player, c.character.id})
    {:ok, _} = DebugSessions.transition("123", "456", :dm)

    assert {:error, :stale_component} =
             Dispatcher.handle(click(button(dm_prompt, "Confirm deletion"), "456"), c.opts)

    assert Repo.get!(Entry, entry.id)
  end

  test "current Nostrum drops Label-wrapper children; legacy format remains isolated" do
    converted =
      event(5, %{
        custom_id: "modern",
        components: [%{type: 18, component: %{type: 4, custom_id: "body", value: "Lost"}}]
      })

    [label] = converted.data.components
    refute Map.has_key?(label, :component)
    assert label.components == nil
    assert Enum.all?(JournalInteractions.modal("fixture").components, &(&1.type == 1))
  end
end
