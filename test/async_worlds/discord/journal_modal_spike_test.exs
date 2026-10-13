defmodule AsyncWorlds.Discord.JournalModalSpikeTest do
  use AsyncWorlds.DataCase, async: false
  import ExUnit.CaptureLog

  alias AsyncWorlds.{Campaigns, Characters, Deliveries}

  alias AsyncWorlds.Discord.{
    Commands,
    DebugSessions,
    Dispatcher,
    FakeAdapter,
    JournalModalSpike,
    NostrumAdapter
  }

  setup do
    start_supervised!({FakeAdapter, owner: self()})
    previous = Application.get_env(:async_worlds, :journal_modal_spike, false)
    Application.put_env(:async_worlds, :journal_modal_spike, true)
    on_exit(fn -> Application.put_env(:async_worlds, :journal_modal_spike, previous) end)

    {:ok, campaign} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "123",
        dm_user_id: "456",
        public_channel_id: "789"
      })

    {:ok, character} =
      Characters.create_character(campaign, "456", %{name: "Explorer", discord_user_id: "999"})

    %{
      campaign: campaign,
      character: character,
      opts: [adapter: FakeAdapter, guild_id: "123", application_id: "111"]
    }
  end

  defp event(type, id, data, user \\ "999") do
    # Exercise the same conversion the real Nostrum gateway uses.
    Nostrum.Struct.Interaction.to_struct(%{
      id: to_string(id),
      application_id: "111",
      type: type,
      guild_id: "123",
      member: %{user: %{id: user, username: "player"}},
      token: "secret-interaction-token",
      data: data
    })
  end

  defp new_event(id, visibility \\ nil, user \\ "999") do
    options = if visibility, do: [%{type: 3, name: "visibility", value: visibility}], else: []

    event(
      2,
      id,
      %{name: "journal", type: 1, options: [%{type: 1, name: "new", options: options}]},
      user
    )
  end

  defp write_button(c, id \\ 1000, visibility \\ nil, user \\ "999") do
    assert {:ok, %{components: [%{components: [%{custom_id: button}]}]}} =
             Dispatcher.handle(new_event(id, visibility, user), c.opts)

    request = to_string(id)
    assert_receive {:discord, :defer, %{id: ^request}}
    assert_receive {:discord, :edit_response, _}
    button
  end

  defp open_modal(c, button, id \\ 1001, user \\ "999") do
    assert {:ok, :modal_opened} =
             Dispatcher.handle(
               event(3, id, %{component_type: 2, custom_id: button}, user),
               c.opts
             )

    assert_receive {:discord, :open_modal, {_, modal}}
    refute_receive {:discord, :defer, _}
    refute_receive {:discord, :edit_response, _}
    modal
  end

  defp submission(
         id,
         modal,
         title \\ "A discovery 🌍",
         body \\ "First line\nSecond line 🧭",
         user \\ "999"
       ) do
    components = [
      %{type: 1, components: [%{type: 4, custom_id: "title", value: title}]},
      %{type: 1, components: [%{type: 4, custom_id: "body", value: body}]}
    ]

    event(5, id, %{custom_id: modal.custom_id, components: components}, user)
  end

  test "legacy modal round-trips Unicode and multiline content with no deferred modal callback",
       c do
    button = write_button(c)
    assert byte_size(button) <= 100
    modal = open_modal(c, button)
    assert byte_size(modal.custom_id) <= 100
    assert NostrumAdapter.modal_response(modal) == %{type: 9, data: modal}
    assert [%{type: 1, components: [title]}, %{type: 1, components: [body]}] = modal.components
    assert title.style == 1 and title.max_length == 100
    assert body.style == 2 and body.max_length == 4000

    submit = submission(1002, modal)

    assert Enum.at(submit.data.components, 1).components |> hd() |> Map.fetch!(:value) ==
             "First line\nSecond line 🧭"

    assert {:ok, preview} = Dispatcher.handle(submit, c.opts)
    assert preview =~ "NOT SAVED"
    assert preview =~ "Intended visibility: private"
    assert preview =~ "A discovery 🌍\n\nFirst line\nSecond line 🧭"
    assert_receive {:discord, :defer, %{id: "1002"}}
    assert_receive {:discord, :edit_response, {_, ^preview}}
    assert Deliveries.list_deliveries(c.campaign.id) == []
    assert Characters.get_character(c.campaign, "456", c.character.id) == {:ok, c.character}
    refute_receive {:discord, :send_public, _}
    refute_receive {:discord, :send_private, _}
  end

  test "public intent still yields only private chunked responses without automatic mentions",
       c do
    modal = open_modal(c, write_button(c, 1100, "public"), 1101)
    body = "@everyone\n" <> String.duplicate("🌍", 3990)
    assert {:ok, preview} = Dispatcher.handle(submission(1102, modal, "Title", body), c.opts)
    assert preview =~ "Intended visibility: public"
    chunks = AsyncWorlds.Discord.Content.chunks(preview)
    assert length(chunks) == 3
    assert_receive {:discord, :defer, _}
    assert_receive {:discord, :edit_response, {_, first}}
    assert_receive {:discord, :followup_response, {_, second}}
    assert_receive {:discord, :followup_response, {_, third}}
    assert first <> second <> third == preview

    for chunk <- chunks do
      assert length(String.codepoints(chunk)) <= 1900
      assert NostrumAdapter.response_data(chunk).allowed_mentions == %{parse: []}
      assert NostrumAdapter.followup_data(chunk).flags == 64
    end

    refute_receive {:discord, :send_public, _}
  end

  test "disabled spike disappears from catalogue and ignores outstanding modal submits", c do
    modal = open_modal(c, write_button(c))
    Application.put_env(:async_worlds, :journal_modal_spike, false)
    refute Enum.any?(Commands.definitions(), &(&1.name == "journal"))
    assert :ignored = Dispatcher.handle(submission(1002, modal), c.opts)
    assert {:error, :unknown_command} = Dispatcher.handle(new_event(1003), c.opts)
    refute_receive {:discord, :open_modal, _}
  end

  test "definition, default visibility, optional choice routing and malformed options", c do
    assert Enum.any?(Commands.definitions(), &(&1.name == "journal"))
    assert {:ok, {:journal_spike_new, "private"}, :player} = Commands.route(new_event(1).data)

    assert {:ok, {:journal_spike_new, "public"}, :player} =
             Commands.route(new_event(1, "public").data)

    assert {:error, :unknown_command} = Dispatcher.handle(new_event(1, "hidden"), c.opts)

    assert {:error, :unknown_command} =
             Commands.route(%{
               name: "journal",
               options: [
                 %{type: 1, name: "new", options: [%{type: 3, name: "character", value: "1"}]}
               ]
             })
  end

  test "envelope, guild and linked ownership checks cannot be bypassed", c do
    assert {:error, :not_found} = Dispatcher.handle(new_event(1000, nil, "777"), c.opts)
    assert_receive {:discord, :defer, _}
    assert_receive {:discord, :edit_response, _}
    button = write_button(c, 1001)
    open = event(3, 1002, %{component_type: 2, custom_id: button})

    for {bad, i} <-
          Enum.with_index(
            [
              %{open | guild_id: 321},
              %{open | member: nil},
              %{open | member: %{user_id: 777}}
            ],
            2000
          ) do
      assert {:error, _} = Dispatcher.handle(%{bad | id: i}, c.opts)
      assert_receive {:discord, :defer, _}
      assert_receive {:discord, :edit_response, _}
    end

    assert :ignored = Dispatcher.handle(%{open | application_id: 222}, c.opts)
    assert :ignored = Dispatcher.handle(%{open | token: nil}, c.opts)
    refute_receive {:discord, :open_modal, _}
  end

  test "another linked player cannot open or submit someone else's controls", c do
    {:ok, _} =
      Characters.create_character(c.campaign, "456", %{name: "Other", discord_user_id: "777"})

    button = write_button(c)

    assert {:error, :stale_component} =
             Dispatcher.handle(
               event(3, 1001, %{component_type: 2, custom_id: button}, "777"),
               c.opts
             )

    assert_receive {:discord, :defer, _}
    assert_receive {:discord, :edit_response, _}
    refute_receive {:discord, :open_modal, _}
    modal = open_modal(c, button, 1002)

    assert {:error, :stale_component} =
             Dispatcher.handle(submission(1003, modal, "Stolen", "Body", "777"), c.opts)
  end

  test "tampered visibility, expired controls and oversized custom IDs fail privately", c do
    button = write_button(c)
    [prefix, action, visibility, _issued, request, sig] = String.split(button, ":")

    expired =
      Enum.join(
        [
          prefix,
          action,
          visibility,
          Integer.to_string(System.system_time(:second) - 901, 36),
          request,
          sig
        ],
        ":"
      )

    for {id, n} <-
          Enum.with_index(
            [
              String.replace(button, ":private:", ":public:"),
              expired,
              button <> String.duplicate("x", 100)
            ],
            2000
          ) do
      assert {:error, :stale_component} =
               Dispatcher.handle(event(3, n, %{component_type: 2, custom_id: id}), c.opts)

      assert_receive {:discord, :defer, _}
      assert_receive {:discord, :edit_response, {_, message}}
      assert message =~ "/journal new"
    end

    refute_receive {:discord, :open_modal, _}
  end

  test "relinking invalidates a modal already opened by the old owner", c do
    modal = open_modal(c, write_button(c))

    {:ok, _} =
      Characters.update_character(c.campaign, "456", c.character.id, %{discord_user_id: "777"})

    assert {:error, :not_found} = Dispatcher.handle(submission(1002, modal), c.opts)

    assert {:error, :stale_component} =
             Dispatcher.handle(submission(1003, modal, "Title", "Body", "777"), c.opts)
  end

  test "accountless DM persona works, but changing away and back invalidates its form", c do
    {:ok, character} = Characters.create_character(c.campaign, "456", %{name: "Accountless"})
    assert {:ok, _} = DebugSessions.transition("123", "456", {:player, character.id})
    modal = open_modal(c, write_button(c, 1000, nil, "456"), 1001, "456")

    assert {:ok, preview} =
             Dispatcher.handle(submission(1002, modal, "Title", "Body", "456"), c.opts)

    assert preview =~ "Testing as Accountless"
    assert_receive {:discord, :defer, _}
    assert_receive {:discord, :edit_response, _}
    assert {:ok, _} = DebugSessions.transition("123", "456", :dm)
    assert {:ok, _} = DebugSessions.transition("123", "456", {:player, character.id})

    assert {:error, :stale_component} =
             Dispatcher.handle(submission(1003, modal, "Title", "Body", "456"), c.opts)
  end

  test "submission rejects blank, oversized, duplicate and unknown inputs", c do
    modal = open_modal(c, write_button(c))

    for {title, body, id} <- [
          {" ", "Body", 2000},
          {"Title", "\n", 2001},
          {String.duplicate("🌍", 101), "Body", 2002},
          {"Title", String.duplicate("x", 4001), 2003}
        ] do
      assert {:error, :invalid_journal_input} =
               Dispatcher.handle(submission(id, modal, title, body), c.opts)
    end

    valid = submission(3000, modal)
    [title_row, _] = valid.data.components

    assert {:error, :invalid_journal_input} =
             Dispatcher.handle(
               %{valid | data: %{valid.data | components: [title_row, title_row]}},
               c.opts
             )

    unknown = %{title_row | components: [%{type: 4, custom_id: "unknown", value: "Body"}]}

    assert {:error, :invalid_journal_input} =
             Dispatcher.handle(
               %{valid | id: 3001, data: %{valid.data | components: [title_row, unknown]}},
               c.opts
             )

    assert {:ok, _} =
             Dispatcher.handle(
               submission(3002, modal, String.duplicate("🌍", 100), String.duplicate("🌍", 4000)),
               c.opts
             )
  end

  test "modal acknowledgment failures never defer again and redact the transport error", c do
    button = write_button(c)
    FakeAdapter.fail(:open_modal, {:error, "secret-interaction-token"})

    log =
      capture_log(fn ->
        assert {:error, :acknowledgment_failed} =
                 Dispatcher.handle(
                   event(3, 1001, %{component_type: 2, custom_id: button}),
                   c.opts
                 )
      end)

    assert_receive {:discord, :open_modal, _}
    refute_receive {:discord, :defer, _}
    refute_receive {:discord, :edit_response, _}
    refute log =~ "secret-interaction-token"
  end

  test "failed submission defer prevents rendering private content; duplicate acknowledgment stops replay",
       c do
    modal = open_modal(c, write_button(c))
    submit = submission(1002, modal)
    FakeAdapter.fail(:defer, {:error, :offline})

    capture_log(fn ->
      assert {:error, :acknowledgment_failed} = Dispatcher.handle(submit, c.opts)
    end)

    assert_receive {:discord, :defer, _}
    refute_receive {:discord, :edit_response, _}
    FakeAdapter.fail(:defer, nil)
    assert {:ok, _} = Dispatcher.handle(submit, c.opts)
    assert_receive {:discord, :defer, _}
    assert_receive {:discord, :edit_response, _}

    capture_log(fn ->
      assert {:error, :acknowledgment_failed} = Dispatcher.handle(submit, c.opts)
    end)

    assert_receive {:discord, :defer, _}
    refute_receive {:discord, :edit_response, _}
  end

  test "campaign reconfiguration invalidates an outstanding form", c do
    modal = open_modal(c, write_button(c))

    assert {:ok, _} =
             Campaigns.setup_campaign(%{
               discord_guild_id: "123",
               dm_user_id: "777",
               public_channel_id: "789"
             })

    assert {:error, :stale_component} = Dispatcher.handle(submission(1002, modal), c.opts)
  end

  test "supervised consumer handles a converted legacy submission without a gateway", c do
    modal = open_modal(c, write_button(c))
    start_supervised!(Nostrum.ConsumerGroup)
    start_supervised!({Task.Supervisor, name: AsyncWorlds.Discord.Tasks, max_children: 100})

    consumer =
      start_supervised!({AsyncWorlds.Discord.Consumer, name: AsyncWorlds.Discord.Consumer})

    previous = Application.fetch_env!(:async_worlds, :discord)
    Application.put_env(:async_worlds, :discord, c.opts)
    on_exit(fn -> Application.put_env(:async_worlds, :discord, previous) end)

    Nostrum.ConsumerGroup.dispatch({:INTERACTION_CREATE, submission(1002, modal), nil})
    _ = :sys.get_state(consumer)
    assert_receive {:discord, :defer, %{id: "1002"}}
    assert_receive {:discord, :edit_response, {_, preview}}
    assert preview =~ "First line\nSecond line 🧭"
    assert Process.whereis(Nostrum.Supervisor) == nil
  end

  test "current Nostrum drops Label-wrapper children, unlike supported legacy rows" do
    converted =
      event(5, 1, %{
        custom_id: "modern",
        components: [%{type: 18, component: %{type: 4, custom_id: "body", value: "Lost text"}}]
      })

    [label] = converted.data.components
    refute Map.has_key?(label, :component)
    assert label.components == nil
    assert JournalModalSpike.modal("fixture").components |> Enum.all?(&(&1.type == 1))
  end
end
