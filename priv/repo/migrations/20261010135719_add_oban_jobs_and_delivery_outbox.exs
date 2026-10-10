defmodule AsyncWorlds.Repo.Migrations.AddObanJobsAndDeliveryOutbox do
  use Ecto.Migration

  def up do
    Oban.Migration.up(version: 14)

    create table(:discord_deliveries) do
      add :campaign_id, references(:campaigns, on_delete: :delete_all), null: false
      add :tick_id, references(:ticks, on_delete: :delete_all), null: false
      add :key, :text, null: false
      add :kind, :text, null: false
      add :recipient_id, :text, null: false
      add :content, :text, null: false
      add :status, :text, null: false, default: "pending"
      add :generation, :integer, null: false, default: 0
      add :attempts, :integer, null: false, default: 0
      add :error_class, :text
      add :last_error, :text
      add :message_id, :text
      add :channel_id, :text
      add :started_at, :utc_datetime_usec
      add :sent_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:discord_deliveries, [:campaign_id, :key])
    create index(:discord_deliveries, [:campaign_id, :status])
    create index(:discord_deliveries, [:tick_id])

    create constraint(:discord_deliveries, :valid_delivery_kind,
             check: "kind IN ('public', 'private')"
           )

    create constraint(:discord_deliveries, :valid_delivery_status,
             check: "status IN ('pending', 'sending', 'sent', 'failed', 'ambiguous')"
           )

    create constraint(:discord_deliveries, :valid_delivery_error_class,
             check: "error_class IN ('retryable', 'permanent', 'ambiguous')"
           )

    create constraint(:discord_deliveries, :valid_delivery_counts,
             check: "generation >= 0 AND attempts >= 0"
           )

    create constraint(:discord_deliveries, :valid_delivery_content,
             check: "char_length(content) BETWEEN 1 AND 2000"
           )
  end

  def down do
    drop table(:discord_deliveries)
    Oban.Migration.down(version: 1)
  end
end
