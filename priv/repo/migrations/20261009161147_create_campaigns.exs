defmodule AsyncWorlds.Repo.Migrations.CreateCampaigns do
  use Ecto.Migration

  def change do
    create table(:campaigns) do
      add :discord_guild_id, :string, size: 20, null: false
      add :dm_user_id, :string, size: 20, null: false
      add :public_channel_id, :string, size: 20, null: false
      add :current_tick_number, :bigint, default: 0, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:campaigns, [:discord_guild_id])

    for field <- [:discord_guild_id, :dm_user_id, :public_channel_id] do
      create constraint(:campaigns, "campaigns_#{field}_valid",
               check:
                 "#{field} ~ '^[1-9][0-9]{0,19}$' AND #{field}::numeric <= 18446744073709551615"
             )
    end

    create constraint(:campaigns, :campaigns_tick_nonnegative, check: "current_tick_number >= 0")
  end
end
