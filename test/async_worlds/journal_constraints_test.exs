defmodule AsyncWorlds.JournalConstraintsTest do
  use AsyncWorlds.DataCase, async: false
  alias AsyncWorlds.{Campaigns, Characters, Journals, PlayerAccess}
  alias AsyncWorlds.Journals.Entry

  setup do
    {:ok, campaign} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "123",
        dm_user_id: "456",
        public_channel_id: "789"
      })

    {:ok, character} =
      Characters.create_character(campaign, "456", %{name: "Player", discord_user_id: "991"})

    {:ok, context} = PlayerAccess.context(campaign, "991")
    {:ok, receipt} = Journals.begin_creation(context, "1000")
    {:ok, result} = Journals.submit(context, receipt.id, %{title: "Title", body: "Body"})

    %{
      campaign: campaign,
      character: character,
      entry: Repo.get!(Entry, result.entry_id),
      receipt: receipt
    }
  end

  for {field, value, constraint} <- [
        {"title", " ", "journal_title_valid"},
        {"title", "\u00a0\u2003\u3000", "journal_title_valid"},
        {"title", String.duplicate("🌍", 101), "journal_title_valid"},
        {"body", "\n\t", "journal_body_valid"},
        {"body", String.duplicate("🌍", 4001), "journal_body_valid"},
        {"visibility", "hidden", "journal_visibility_valid"},
        {"origin", "unknown", "journal_origin_valid"}
      ] do
    @field field
    @value value
    @constraint constraint
    test "database rejects invalid #{@field} #{inspect(String.slice(@value, 0, 8))}", c do
      assert {:error, %Postgrex.Error{postgres: %{constraint: constraint}}} =
               Repo.query(
                 "UPDATE journal_entries SET #{@field} = $1 WHERE id = $2",
                 [@value, c.entry.id],
                 log: false
               )

      assert constraint == @constraint
    end
  end

  test "composite character/campaign FK rejects a foreign campaign character", c do
    {:ok, foreign} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "124",
        dm_user_id: "457",
        public_channel_id: "790"
      })

    {:ok, character} = Characters.create_character(foreign, "457", %{name: "Foreign"})

    assert {:error, %Postgrex.Error{postgres: %{code: :foreign_key_violation}}} =
             Repo.query(
               "UPDATE journal_entries SET character_id = $1 WHERE id = $2",
               [character.id, c.entry.id],
               log: false
             )
  end

  test "retained history prevents silent character cascade", c do
    assert {:error, %Postgrex.Error{postgres: %{code: :foreign_key_violation}}} =
             Repo.query("DELETE FROM characters WHERE id = $1", [c.character.id], log: false)
  end

  test "one receipt cannot identify two entries", c do
    assert {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} =
             Repo.query(
               "INSERT INTO journal_entries (campaign_id, character_id, receipt_id, author_discord_user_id, origin, visibility, title, body, inserted_at, updated_at) SELECT campaign_id, character_id, receipt_id, author_discord_user_id, origin, visibility, title, body, inserted_at, updated_at FROM journal_entries WHERE id = $1",
               [c.entry.id],
               log: false
             )
  end

  test "creation request identity is unique even without application authorization", c do
    assert {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} =
             Repo.query(
               "INSERT INTO journal_creation_receipts (id, campaign_id, character_id, request_id, actor_id, binding, origin, visibility, expires_at, state, inserted_at, updated_at) SELECT $1::uuid, campaign_id, character_id, request_id, actor_id, binding, origin, visibility, expires_at, 'pending', inserted_at, updated_at FROM journal_creation_receipts WHERE id = $2::uuid",
               [Ecto.UUID.bingenerate(), Ecto.UUID.dump!(c.receipt.id)],
               log: false
             )
  end
end
