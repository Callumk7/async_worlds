defmodule AsyncWorlds.Journals.CreationTest do
  use AsyncWorlds.DataCase, async: false
  import ExUnit.CaptureLog
  alias AsyncWorlds.{Campaigns, Characters, Journals, PlayerAccess}
  alias AsyncWorlds.Discord.{DebugSessions, JournalCreation}
  alias AsyncWorlds.Journals.{CreationReceipt, Entry}

  setup do
    {:ok, campaign} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "123",
        dm_user_id: "456",
        public_channel_id: "789"
      })

    {:ok, character} =
      Characters.create_character(campaign, "456", %{name: "Player", discord_user_id: "991"})

    {:ok, other} =
      Characters.create_character(campaign, "456", %{name: "Other", discord_user_id: "992"})

    {:ok, player} = PlayerAccess.context(campaign, "991")

    %{
      campaign: campaign,
      character: character,
      other: other,
      player: player,
      scope: %{campaign: campaign, discord_user_id: "456"}
    }
  end

  @attrs %{title: "Title", body: "Private body"}

  test "creates directly with a generic key and ignores supplied attribution fields", c do
    attrs =
      Map.merge(@attrs, %{
        campaign_id: -1,
        character_id: c.other.id,
        author_discord_user_id: "992",
        origin: :dm,
        visibility: :public
      })

    assert {:ok, %{state: :completed, entry_id: id} = result} =
             Journals.create_entry("123", "991", "journal-request/one", attrs)

    entry = Repo.get!(Entry, id)
    assert entry.character_id == c.character.id
    assert entry.author_discord_user_id == "991"
    assert entry.origin == :player
    assert entry.visibility == :private
    assert {:ok, ^result} = Journals.create_entry("123", 991, "journal-request/one", @attrs)
    assert Repo.aggregate(Entry, :count) == 1
    receipt = Repo.get!(CreationReceipt, result.id)
    refute inspect(receipt) =~ "Private body"
    refute inspect(receipt) =~ "journal-request/one"
    assert String.starts_with?(receipt.request_id, "direct:")
  end

  test "key reuse for changed content, visibility or target conflicts atomically", c do
    {:ok, result} = Journals.create_dm_entry(c.scope, c.character.id, "same", @attrs)

    assert {:error, :idempotency_conflict} =
             Journals.create_dm_entry(c.scope, c.character.id, "same", %{@attrs | body: "Changed"})

    assert {:error, :idempotency_conflict} =
             Journals.create_dm_entry(c.scope, c.character.id, "same", @attrs, "public")

    assert {:error, :idempotency_conflict} =
             Journals.create_dm_entry(c.scope, c.other.id, "same", @attrs)

    assert Repo.aggregate(Entry, :count) == 1
    assert Repo.get!(Entry, result.entry_id).body == @attrs.body
  end

  test "request identities are independent across actors, campaigns and Discord modal flows", c do
    key = "1000"
    assert {:ok, first} = Journals.create_entry("123", "991", key, @attrs)
    assert {:ok, second} = Journals.create_entry("123", "992", key, @attrs)
    refute first.id == second.id
    assert {:ok, modal} = JournalCreation.begin_creation(c.player, key)
    assert {:ok, third} = JournalCreation.submit(c.player, modal.id, @attrs)
    refute third.id in [first.id, second.id]
    # Existing modal controls cannot be used to access direct creation outcomes.
    assert {:error, :stale_component} = JournalCreation.open_creation(c.player, first.id)
    assert {:error, :stale_component} = JournalCreation.submit(c.player, first.id, @attrs)

    {:ok, campaign} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "124",
        dm_user_id: "456",
        public_channel_id: "790"
      })

    {:ok, _} =
      Characters.create_character(campaign, "456", %{name: "Elsewhere", discord_user_id: "991"})

    assert {:ok, fourth} = Journals.create_entry("124", "991", key, @attrs)
    refute fourth.id == first.id
  end

  test "DM creation selects a campaign character explicitly without changing persona and records actual author",
       c do
    {:ok, _} = DebugSessions.transition("123", "456", {:player, c.other.id})
    before = DebugSessions.current(c.campaign)

    assert {:ok, result} =
             Journals.create_dm_entry(
               c.scope,
               to_string(c.character.id),
               Ecto.UUID.generate(),
               @attrs,
               :public
             )

    entry = Repo.get!(Entry, result.entry_id)
    assert entry.character_id == c.character.id
    assert entry.author_discord_user_id == "456"
    assert entry.origin == :dm
    assert entry.visibility == :public
    assert DebugSessions.current(c.campaign) == before
    {:ok, accountless} = Characters.create_character(c.campaign, "456", %{name: "Accountless"})
    assert {:ok, _} = Journals.create_dm_entry(c.scope, accountless.id, "accountless", @attrs)
  end

  test "DM revocation, invalid subjects and foreign characters fail closed", c do
    assert {:error, :not_found} = Journals.create_entry("123", "993", "no-subject", @attrs)

    assert {:error, :unauthorized} =
             Journals.create_dm_entry(
               %{c.scope | discord_user_id: "991"},
               c.character.id,
               "no",
               @attrs
             )

    {:ok, foreign} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "124",
        dm_user_id: "456",
        public_channel_id: "790"
      })

    {:ok, character} = Characters.create_character(foreign, "456", %{name: "Foreign"})

    for id <- [character.id, nil, "bad", "9223372036854775808"] do
      assert {:error, :not_found} = Journals.create_dm_entry(c.scope, id, "invalid", @attrs)
    end

    {:ok, _} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "123",
        dm_user_id: "457",
        public_channel_id: "789"
      })

    assert {:error, :unauthorized} =
             Journals.create_dm_entry(c.scope, c.character.id, "revoked", @attrs)

    assert Repo.aggregate(Entry, :count) == 0
    assert Repo.aggregate(CreationReceipt, :count) == 0
  end

  test "player ownership changes cannot inherit a former owner's idempotency outcome", c do
    {:ok, result} = Journals.create_entry("123", "991", "owned", @attrs)

    {:ok, _} =
      Characters.update_character(c.campaign, "456", c.character.id, %{discord_user_id: "993"})

    assert {:error, :not_found} = Journals.create_entry("123", "991", "owned", @attrs)
    assert {:ok, replacement} = Journals.create_entry("123", "993", "owned", @attrs)
    refute replacement.entry_id == result.entry_id
    assert {:error, :not_found} = Journals.get_entry(c.player, result.entry_id)
  end

  test "direct deleted outcomes persist and never resurrect content on replay", c do
    {:ok, result} = Journals.create_entry("123", "991", "retained", @attrs)
    {:ok, target} = Journals.prepare_delete(c.player, result.entry_id)
    assert {:ok, :deleted} = Journals.delete_entry(c.player, result.entry_id, target.binding)

    assert {:ok, %{state: :deleted, entry_id: id}} =
             Journals.create_entry("123", "991", "retained", @attrs)

    assert id == result.entry_id
    assert Repo.get(Entry, id) == nil

    assert {:error, :idempotency_conflict} =
             Journals.create_entry("123", "991", "retained", %{@attrs | body: "Resurrection"})
  end

  test "generic creation outcomes do not expire like modal controls" do
    {:ok, result} = Journals.create_entry("123", "991", "durable", @attrs)

    Repo.get!(CreationReceipt, result.id)
    |> change(expires_at: ~U[2000-01-01 00:00:00.000000Z])
    |> Repo.update!()

    assert {:ok, ^result} = Journals.create_entry("123", "991", "durable", @attrs)
  end

  test "invalid keys/content create no receipt, entry or logged draft", c do
    for key <- [nil, 123, "", " ", <<0>>, <<255>>, String.duplicate("x", 201)] do
      assert {:error, :invalid_idempotency_key} = Journals.create_entry("123", "991", key, @attrs)
    end

    log =
      capture_log(fn ->
        for attrs <- [
              %{title: "Secret title", body: ""},
              %{title: "Secret title", body: <<0>>},
              %{title: "", body: "Private draft"},
              %{},
              nil
            ] do
          assert {:error, :invalid_journal_input} =
                   Journals.create_entry("123", "991", "invalid", attrs)
        end

        assert {:error, :invalid_journal_input} =
                 Journals.create_dm_entry(c.scope, c.character.id, "invalid", @attrs, "hidden")
      end)

    refute log =~ "Secret title"
    refute log =~ "Private draft"
    assert Repo.aggregate(Entry, :count) == 0
    assert Repo.aggregate(CreationReceipt, :count) == 0
  end

  test "direct player creation preserves persona checks and attribution", c do
    {:ok, _} = DebugSessions.transition("123", "456", {:player, c.character.id})
    {:ok, context} = PlayerAccess.context(c.campaign, "456")
    assert {:ok, result} = Journals.create_entry("123", context.access, "persona", @attrs)
    entry = Repo.get!(Entry, result.entry_id)
    assert entry.author_discord_user_id == "456"
    assert entry.character_id == c.character.id
    assert entry.origin == :dm_persona
    {:ok, _} = DebugSessions.transition("123", "456", :off)

    assert {:error, :stale_component} =
             Journals.create_entry("123", context.access, "persona", @attrs)
  end
end
