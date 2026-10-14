defmodule AsyncWorlds.Repo.Migrations.CreateTickBriefings do
  use Ecto.Migration

  def change do
    create table(:tick_briefings) do
      add :tick_id, references(:ticks, on_delete: :delete_all), null: false
      add :narration, :text, null: false
      add :renderer_version, :integer, null: false
      add :input_version, :text, null: false
      add :public_channel_id, :text, null: false
      add :outputs, :map, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:tick_briefings, [:tick_id])
  end
end
