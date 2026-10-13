defmodule AsyncWorlds.JournalsTest do
  use AsyncWorlds.DataCase, async: false
  alias AsyncWorlds.{Campaigns, Characters, Journals, PlayerAccess, Ticks}
  alias AsyncWorlds.Discord.DebugSessions
  alias AsyncWorlds.Journals.{CreationReceipt, Entry}

  setup do
    {:ok, campaign} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "123",
        dm_user_id: "456",
        public_channel_id: "789"
      })

    {:ok, a} = Characters.create_character(campaign, "456", %{name: "A", discord_user_id: "991"})
    {:ok, b} = Characters.create_character(campaign, "456", %{name: "B", discord_user_id: "992"})

    %{
      campaign: campaign,
      a: a,
      b: b,
      player: context(campaign, "991"),
      other: context(campaign, "992"),
      dm: context(campaign, "456")
    }
  end

  defp context(campaign, actor) do
    {:ok, context} = PlayerAccess.context(campaign, actor)
    context
  end

  defp begin(context, visibility \\ "private"),
    do: Journals.begin_creation(context, System.unique_integer([:positive]), visibility)

  defp save(context, visibility \\ "private", attrs \\ %{title: "Title", body: "Body"}) do
    {:ok, receipt} = begin(context, visibility)
    {:ok, result} = Journals.submit(context, receipt.id, attrs)
    Repo.get!(Entry, result.entry_id)
  end

  defp delete(context, entry) do
    {:ok, target} = Journals.prepare_delete(context, entry.id)
    Journals.delete_entry(context, entry.id, target.binding)
  end

  test "default-private persistent flow and immutable trusted fields; duplicates never replace content",
       c do
    request = System.unique_integer([:positive])
    assert {:ok, first} = Journals.begin_creation(c.player, request)
    assert {:ok, ^first} = Journals.begin_creation(c.player, request)
    assert {:ok, ^first} = Journals.open_creation(c.player, first.id)
    assert Repo.aggregate(Entry, :count) == 0

    attrs = %{
      title: "Title",
      body: "\n  Body 🌍\n",
      visibility: "public",
      origin: "dm_persona",
      author_discord_user_id: "992",
      character_id: c.b.id,
      campaign_id: 999,
      id: 999
    }

    assert {:ok, result} = Journals.submit(c.player, first.id, attrs)
    entry = Repo.get!(Entry, result.entry_id)
    assert entry.campaign_id == c.campaign.id
    assert entry.character_id == c.a.id
    assert entry.author_discord_user_id == "991"
    assert entry.origin == :player
    assert entry.visibility == :private
    assert entry.body == attrs.body

    assert {:ok, ^result} =
             Journals.submit(c.player, first.id, %{title: "Different", body: "Ignored"})

    assert Repo.get!(Entry, entry.id) == entry
    assert {:ok, ^result} = Journals.begin_creation(c.player, request)
    assert {:error, :stale_component} = Journals.begin_creation(c.player, request, "public")
    assert {:error, :stale_component} = Journals.begin_creation(c.other, request)
    assert save(c.player).id != entry.id
  end

  test "private and public reads/lists are campaign-scoped with metadata-only bounded projections",
       c do
    private = save(c.player)
    public = save(c.player, "public")
    theirs = save(c.other)
    assert {:ok, %{entries: mine}} = Journals.list_entries(c.player)
    assert Enum.map(mine, & &1.id) == [public.id, private.id]

    for row <- mine do
      assert Enum.sort(Map.keys(row)) ==
               Enum.sort([:id, :title, :character, :visibility, :inserted_at])
    end

    assert {:ok, %{entries: [%{id: id}]}} = Journals.list_entries(c.other, :public)
    assert id == public.id
    assert {:error, :not_found} = Journals.get_entry(c.other, private.id)
    assert {:error, :not_found} = Journals.prepare_delete(c.other, public.id)
    assert {:error, :not_found} = Journals.get_entry(c.player, theirs.id)
    assert {:ok, %{id: id, can_delete?: false}} = Journals.get_entry(c.other, public.id)
    assert id == public.id

    {:ok, campaign} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "124",
        dm_user_id: "457",
        public_channel_id: "790"
      })

    {:ok, _} =
      Characters.create_character(campaign, "457", %{
        name: "Other campaign",
        discord_user_id: "991"
      })

    foreign = save(context(campaign, "991"), "public")
    assert {:error, :not_found} = Journals.get_entry(c.player, foreign.id)
    assert {:ok, %{entries: entries}} = Journals.list_entries(c.player, :public)
    assert Enum.map(entries, & &1.id) == [public.id]
    assert {:error, :unauthorized} = Journals.list_entries(c.player, :character, c.b.id)
    assert {:error, :unauthorized} = Journals.list_entries(c.player, :mine, c.b.id)
  end

  test "approved character-owned policy transfers private read/delete but retains original attribution",
       c do
    entry = save(c.player)
    {:ok, target} = Journals.prepare_delete(c.player, entry.id)
    {:ok, _} = Characters.update_character(c.campaign, "456", c.a.id, %{discord_user_id: "993"})
    new_owner = context(c.campaign, "993")
    assert {:error, :not_found} = Journals.get_entry(c.player, entry.id)
    assert {:error, :not_found} = Journals.delete_entry(c.player, entry.id, target.binding)

    assert {:ok, %{author_discord_user_id: "991", can_delete?: true}} =
             Journals.get_entry(new_owner, entry.id)

    assert {:ok, %{entries: [%{id: id}]}} = Journals.list_entries(new_owner)
    assert id == entry.id
    assert {:ok, :deleted} = delete(new_owner, entry)
  end

  test "DM without a character can inspect/moderate; player persona and former DM cannot bypass boundary",
       c do
    entry = save(c.player)
    assert {:ok, %{entries: [%{id: id}]}} = Journals.list_entries(c.dm, :character, c.a.id)
    assert id == entry.id
    assert {:ok, _} = Journals.get_entry(c.dm, entry.id)
    assert {:ok, %{entries: []}} = Journals.list_entries(c.dm, :public)
    {:ok, target} = Journals.prepare_delete(c.dm, entry.id)
    {:ok, _} = DebugSessions.transition("123", "456", {:player, c.b.id})
    persona = context(c.campaign, "456")
    assert {:error, :not_found} = Journals.get_entry(persona, entry.id)
    assert {:error, :unauthorized} = Journals.list_entries(persona, :character, c.a.id)
    assert {:error, :unauthorized} = Journals.get_entry(c.dm, entry.id)
    assert {:error, :unauthorized} = Journals.delete_entry(c.dm, entry.id, target.binding)
    {:ok, _} = DebugSessions.transition("123", "456", :dm)

    assert {:error, :stale_component} =
             Journals.delete_entry(context(c.campaign, "456"), entry.id, target.binding)

    assert {:ok, :deleted} = delete(context(c.campaign, "456"), entry)
    retained = save(c.player)

    {:ok, _} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "123",
        dm_user_id: "457",
        public_channel_id: "789"
      })

    assert {:error, :unauthorized} = Journals.get_entry(c.dm, retained.id)

    assert {:ok, _} =
             Journals.get_entry(
               context(Campaigns.fetch_campaign_by_guild("123") |> elem(1), "457"),
               retained.id
             )
  end

  test "DM persona origin is explicit and attribution remains actual DM, including later linkage",
       c do
    {:ok, accountless} = Characters.create_character(c.campaign, "456", %{name: "Accountless"})
    {:ok, _} = DebugSessions.transition("123", "456", {:player, accountless.id})
    persona = context(c.campaign, "456")
    entry = save(persona)
    assert entry.character_id == accountless.id and entry.origin == :dm_persona
    assert entry.author_discord_user_id == "456"
    {:ok, _} = DebugSessions.transition("123", "456", :dm)

    {:ok, _} =
      Characters.update_character(c.campaign, "456", accountless.id, %{discord_user_id: "993"})

    owner = context(c.campaign, "993")
    assert {:ok, _} = Journals.get_entry(owner, entry.id)
    assert {:ok, :deleted} = delete(owner, entry)
    {:ok, _} = DebugSessions.transition("123", "456", {:player, c.a.id})
    persona = context(c.campaign, "456")
    player_entry = save(c.player)
    assert {:ok, _} = Journals.get_entry(persona, player_entry.id)
    assert {:ok, :deleted} = delete(persona, player_entry)
  end

  test "message-copy toggles do not expire journal controls or flows", c do
    {:ok, _} =
      Characters.create_character(c.campaign, "456", %{
        name: "DM's character",
        discord_user_id: "456"
      })

    dm = context(c.campaign, "456")
    {:ok, flow} = begin(dm)
    {:ok, binding} = Journals.control_binding(dm, true)
    {:ok, _} = DebugSessions.transition("123", "456", {:messages, true})
    assert {:ok, ^binding} = Journals.control_binding(context(c.campaign, "456"), true)

    assert {:ok, _} =
             Journals.submit(context(c.campaign, "456"), flow.id, %{title: "Title", body: "Body"})
  end

  test "expired/canceled flows and subject/configuration ABA never create or retarget entries",
       c do
    {:ok, receipt} = begin(c.player)

    Repo.get!(CreationReceipt, receipt.id)
    |> change(expires_at: DateTime.add(DateTime.utc_now(), -1))
    |> Repo.update!()

    assert {:error, :stale_component} = Journals.open_creation(c.player, receipt.id)

    assert {:error, :stale_component} =
             Journals.submit(c.player, receipt.id, %{title: "Title", body: "Body"})

    {:ok, canceled} = begin(c.player)
    assert {:ok, %{state: :canceled}} = Journals.cancel_creation(c.player, canceled.id)

    assert {:error, :stale_component} =
             Journals.submit(c.player, canceled.id, %{title: "Title", body: "Body"})

    {:ok, stale} = begin(c.player)
    {:ok, _} = Characters.update_character(c.campaign, "456", c.a.id, %{discord_user_id: "993"})
    {:ok, _} = Characters.update_character(c.campaign, "456", c.a.id, %{discord_user_id: "991"})

    assert {:error, :stale_component} =
             Journals.submit(c.player, stale.id, %{title: "Title", body: "Body"})

    {:ok, _} = DebugSessions.transition("123", "456", {:player, c.a.id})
    persona = context(c.campaign, "456")
    {:ok, flow} = begin(persona)
    {:ok, _} = DebugSessions.transition("123", "456", {:player, c.b.id})
    {:ok, _} = DebugSessions.transition("123", "456", {:player, c.a.id})

    assert {:error, :stale_component} =
             Journals.submit(context(c.campaign, "456"), flow.id, %{title: "Title", body: "Body"})

    assert Repo.aggregate(Entry, :count) == 0
  end

  test "hard deletion is idempotent, keeps content-free receipt, and replay cannot resurrect",
       c do
    entry = save(c.player)
    receipt = Repo.get!(CreationReceipt, entry.receipt_id)
    {:ok, target} = Journals.prepare_delete(c.player, entry.id)
    assert {:ok, :deleted} = Journals.delete_entry(c.player, entry.id, target.binding)
    assert {:ok, :already_deleted} = Journals.delete_entry(c.player, entry.id, target.binding)
    assert {:error, :not_found} = Journals.get_entry(c.player, entry.id)
    assert {:ok, %{entries: []}} = Journals.list_entries(c.player)

    assert {:ok, %{state: :deleted, entry_id: id}} =
             Journals.submit(c.player, receipt.id, %{title: "Resurrection", body: "Not saved"})

    assert id == entry.id
    stored = Repo.get!(CreationReceipt, receipt.id)
    refute Map.has_key?(stored, :title)
    refute Map.has_key?(stored, :body)
    assert stored.binding == receipt.binding
    assert Repo.aggregate(Entry, :count) == 0
  end

  test "confirmation binding cannot delete a different target", c do
    first = save(c.player)
    second = save(c.player)
    {:ok, target} = Journals.prepare_delete(c.player, first.id)
    assert {:error, :stale_component} = Journals.delete_entry(c.player, second.id, target.binding)
    assert Repo.get!(Entry, first.id)
    assert Repo.get!(Entry, second.id)
  end

  test "journal SQL debug logging never contains title/body parameters", c do
    previous = Logger.level()

    try do
      Logger.configure(level: :debug)

      log =
        ExUnit.CaptureLog.capture_log([level: :debug], fn ->
          entry =
            save(c.player, "private", %{
              title: "private-title-marker",
              body: "private-body-marker"
            })

          assert {:ok, _} = Journals.get_entry(c.player, entry.id)
          assert {:ok, _} = Journals.list_entries(c.player)
          assert {:ok, :deleted} = delete(c.player, entry)
        end)

      refute log =~ "private-title-marker"
      refute log =~ "private-body-marker"
    after
      Logger.configure(level: previous)
    end
  end

  test "a dangling completed reference is already-deleted, never permission to recreate", c do
    entry = save(c.player)
    Repo.delete!(entry)

    assert {:ok, %{state: :deleted}} =
             Journals.submit(c.player, entry.receipt_id, %{title: "New", body: "New"})

    {:ok, binding} = Journals.control_binding(c.player)

    assert {:ok, :already_deleted} =
             Journals.delete_entry(c.player, entry.id, Map.put(binding, "target", entry.id))

    assert Repo.aggregate(Entry, :count) == 0
  end

  test "bounded keyset Next/Previous excludes new insertions until refresh and handles deleted windows",
       c do
    entries = for _ <- 1..25, do: save(c.player, "public")
    assert {:ok, first} = Journals.list_entries(c.player)
    assert length(first.entries) == 10 and first.previous == nil and first.next != nil
    assert {:ok, second} = Journals.list_entries(c.player, :mine, nil, first.next)
    assert length(second.entries) == 10 and second.previous != nil and second.next != nil
    assert {:ok, third} = Journals.list_entries(c.player, :mine, nil, second.next)
    assert length(third.entries) == 5 and third.next == nil
    assert {:ok, back} = Journals.list_entries(c.player, :mine, nil, third.previous)
    assert Enum.map(back.entries, & &1.id) == Enum.map(second.entries, & &1.id)
    newest = save(c.player)
    assert {:ok, back} = Journals.list_entries(c.player, :mine, nil, second.previous)
    refute Enum.any?(back.entries, &(&1.id == newest.id))
    assert Enum.map(back.entries, & &1.id) == Enum.map(first.entries, & &1.id)
    for entry <- Enum.take(entries, 15), do: delete(c.player, entry)
    assert {:ok, empty} = Journals.list_entries(c.player, :mine, nil, first.next)
    assert empty.entries == [] and empty.previous != nil
    assert {:ok, recovered} = Journals.list_entries(c.player, :mine, nil, empty.previous)
    assert length(recovered.entries) == 10
    assert {:ok, refreshed} = Journals.list_entries(c.player)
    assert hd(refreshed.entries).id == newest.id

    for cursor <- [
          %{direction: :next, anchor: 0, ceiling: 1},
          %{direction: :next, anchor: 2, ceiling: 1},
          %{direction: :other, anchor: 1, ceiling: 2},
          %{direction: :next, anchor: 1, ceiling: 9_223_372_036_854_775_808},
          "invalid"
        ] do
      assert {:error, :stale_component} = Journals.list_entries(c.player, :mine, nil, cursor)
    end
  end

  test "resolving and in-review ticks do not lock journal operations or enter snapshot/outbox",
       c do
    {:ok, tick} = Ticks.open_tick(c.campaign.id)
    {:ok, %{snapshot: snapshot}} = Ticks.close_tick(c.campaign.id, tick.id)
    assert Repo.get!(AsyncWorlds.Campaigns.Campaign, c.campaign.id).clock_mutations_locked
    before_deliveries = Repo.aggregate(AsyncWorlds.Deliveries.Delivery, :count)
    entry = save(c.player)
    assert {:ok, _} = Journals.get_entry(c.player, entry.id)
    assert {:ok, :deleted} = delete(c.player, entry)
    assert {:ok, _} = Ticks.put_draft(c.campaign.id, tick.id, snapshot.revision, %{})
    assert save(c.player).id
    assert Repo.aggregate(AsyncWorlds.Deliveries.Delivery, :count) == before_deliveries
    refute Map.has_key?(snapshot.data, "journals")
  end

  test "schema rejects boundaries and malformed/NUL text, allowing identical titles and new entries",
       c do
    for {title, body} <- [
          {"", "Body"},
          {"Title", "\n"},
          {String.duplicate("🌍", 101), "Body"},
          {"Title", String.duplicate("🌍", 4001)},
          {"Title", <<255>>},
          {"Title", <<0>>}
        ] do
      {:ok, flow} = begin(c.player)

      assert {:error, :invalid_journal_input} =
               Journals.submit(c.player, flow.id, %{title: title, body: body})

      assert Repo.get!(CreationReceipt, flow.id).state == :pending
    end

    attrs = %{title: String.duplicate("🌍", 100), body: String.duplicate("🌍", 4000)}
    assert save(c.player, "private", attrs).body == attrs.body
    assert save(c.player, "private", attrs).title == attrs.title
    assert Repo.aggregate(Entry, :count) == 2
  end
end
