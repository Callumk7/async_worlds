defmodule AsyncWorlds.Repo.Migrations.AddDmJournalCreationOrigin do
  use Ecto.Migration

  def up do
    for table <- [:journal_creation_receipts, :journal_entries] do
      drop constraint(table, :journal_origin_valid)

      create constraint(table, :journal_origin_valid,
               check: "origin IN ('player', 'dm_persona', 'dm')"
             )
    end
  end

  def down do
    # Downgrade fails rather than silently rewriting existing DM attribution.
    for table <- [:journal_creation_receipts, :journal_entries] do
      drop constraint(table, :journal_origin_valid)
      create constraint(table, :journal_origin_valid, check: "origin IN ('player', 'dm_persona')")
    end
  end
end
