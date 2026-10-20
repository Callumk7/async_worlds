defmodule AsyncWorlds.Repo.Migrations.AddCampaignTensionParticipation do
  use Ecto.Migration

  # Explicit per-campaign adoption of Tension-led participation (ENG-96).
  # Existing campaigns keep their quest-centred entry points until a DM opts in.
  def change do
    alter table(:campaigns) do
      add :tension_participation, :boolean, null: false, default: false
    end
  end
end
