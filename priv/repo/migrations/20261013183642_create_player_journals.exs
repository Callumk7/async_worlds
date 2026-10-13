defmodule AsyncWorlds.Repo.Migrations.CreatePlayerJournals do
  use Ecto.Migration

  def change do
    create table(:journal_creation_receipts, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :campaign_id, references(:campaigns), null: false
      add :character_id, :bigint, null: false
      add :request_id, :string, null: false
      add :actor_id, :string, null: false
      add :binding, :map, null: false
      add :origin, :string, null: false
      add :visibility, :string, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :state, :string, null: false, default: "pending"
      # Deliberately not an FK: retain the original identity after hard deletion.
      add :entry_id, :bigint
      timestamps(type: :utc_datetime_usec)
    end

    execute "ALTER TABLE journal_creation_receipts ADD CONSTRAINT journal_receipt_character_fk FOREIGN KEY (character_id, campaign_id) REFERENCES characters(id, campaign_id)",
            "ALTER TABLE journal_creation_receipts DROP CONSTRAINT IF EXISTS journal_receipt_character_fk"

    create unique_index(:journal_creation_receipts, [:campaign_id, :request_id])
    create unique_index(:journal_creation_receipts, [:entry_id])
    create unique_index(:journal_creation_receipts, [:id, :campaign_id, :character_id])

    create constraint(:journal_creation_receipts, :journal_receipt_state_valid,
             check:
               "(state IN ('pending', 'canceled') AND entry_id IS NULL) OR (state IN ('completed', 'deleted') AND entry_id IS NOT NULL)"
           )

    create table(:journal_entries) do
      add :campaign_id, references(:campaigns), null: false
      add :character_id, :bigint, null: false
      add :receipt_id, :uuid, null: false
      add :author_discord_user_id, :string, null: false
      add :origin, :string, null: false
      add :visibility, :string, null: false, default: "private"
      add :title, :text, null: false
      add :body, :text, null: false
      timestamps(type: :utc_datetime_usec)
    end

    execute "ALTER TABLE journal_entries ADD CONSTRAINT journal_entry_character_fk FOREIGN KEY (character_id, campaign_id) REFERENCES characters(id, campaign_id)",
            "ALTER TABLE journal_entries DROP CONSTRAINT IF EXISTS journal_entry_character_fk"

    execute "ALTER TABLE journal_entries ADD CONSTRAINT journal_entry_receipt_fk FOREIGN KEY (receipt_id, campaign_id, character_id) REFERENCES journal_creation_receipts(id, campaign_id, character_id)",
            "ALTER TABLE journal_entries DROP CONSTRAINT IF EXISTS journal_entry_receipt_fk"

    create unique_index(:journal_entries, [:receipt_id])
    create index(:journal_entries, [:campaign_id, :character_id, :id])
    create index(:journal_entries, [:campaign_id, :id], where: "visibility = 'public'")

    # Match Unicode whitespace handled by String.trim, independent of DB locale.
    whitespace =
      Enum.map_join(
        [9, 10, 11, 12, 13, 32, 133, 160, 5760] ++
          Enum.to_list(8192..8202) ++ [8232, 8233, 8239, 8287, 12288],
        &<<&1::utf8>>
      )

    for {field, max, name} <- [
          {:title, 100, :journal_title_valid},
          {:body, 4000, :journal_body_valid}
        ] do
      create constraint(:journal_entries, name,
               check:
                 "char_length(#{field}) BETWEEN 1 AND #{max} AND char_length(btrim(#{field}, '#{whitespace}')) > 0"
             )
    end

    for table <- [:journal_creation_receipts, :journal_entries] do
      create constraint(table, :journal_visibility_valid,
               check: "visibility IN ('private', 'public')"
             )

      create constraint(table, :journal_origin_valid, check: "origin IN ('player', 'dm_persona')")
    end
  end
end
