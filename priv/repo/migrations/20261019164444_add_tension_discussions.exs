defmodule AsyncWorlds.Repo.Migrations.AddTensionDiscussions do
  use Ecto.Migration

  def change do
    alter table(:tensions) do
      add :audience, :string, null: false, default: "dm"
    end

    create table(:tension_discussions) do
      add :campaign_id, references(:campaigns, on_delete: :delete_all), null: false
      add :tension_id, references(:tensions, on_delete: :delete_all), null: false
      add :parent_id, :string, null: false
      add :guild_id, :string, null: false
      add :name, :string, null: false
      add :thread_id, :string
      add :status, :string, null: false, default: "pending"
      add :generation, :integer, null: false, default: 1
      add :recovery, :map, null: false, default: %{}
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:tension_discussions, [:tension_id])
    create unique_index(:tension_discussions, [:thread_id])

    create table(:tension_discussion_intents) do
      add :discussion_id, references(:tension_discussions, on_delete: :delete_all), null: false
      add :tick_id, references(:ticks, on_delete: :delete_all), null: false
      add :key, :string, null: false
      add :content, :text, null: false
      add :overview, :text
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:tension_discussion_intents, [:discussion_id, :key])
  end
end
