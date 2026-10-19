defmodule AsyncWorlds.Repo.Migrations.AddTensionCommitments do
  use Ecto.Migration

  def change do
    create table(:tension_commitments) do
      add :campaign_id, references(:campaigns, on_delete: :delete_all), null: false
      add :tick_id, references(:ticks, on_delete: :delete_all), null: false
      add :tension_id, references(:tensions, on_delete: :delete_all), null: false
      add :character_id, references(:characters, on_delete: :delete_all), null: false
      add :version, :integer, null: false, default: 1
      add :state, :string, null: false
      add :intention, :text
      add :approach, :text
      add :ready, :boolean, null: false, default: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:tension_commitments, [:tick_id, :tension_id, :character_id])

    create constraint(:tension_commitments, :commitment_state,
             check:
               "state IN ('unresolved', 'confirmed', 'withdrawn') AND version > 0 AND (NOT ready OR state = 'confirmed')"
           )

    create constraint(:tension_commitments, :commitment_text_limits,
             check: "char_length(intention) <= 2000 AND char_length(approach) <= 2000"
           )
  end
end
