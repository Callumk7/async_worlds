defmodule AsyncWorlds.Repo.Migrations.AddTickToClockAudits do
  use Ecto.Migration

  def change do
    alter table(:clock_audits) do
      add :tick_id, references(:ticks, on_delete: :nilify_all)
    end

    create index(:clock_audits, [:tick_id])
  end
end
