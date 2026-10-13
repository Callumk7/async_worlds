defmodule AsyncWorlds.Quests.WorkingCopy do
  use Ecto.Schema

  schema "quest_working_copies" do
    field :campaign_id, :id
    field :quest_id, :id
    field :base_revision_id, :id
    field :name, :string, default: ""
    field :content_id, :string, default: ""
    field :definition, :map
    field :source_definition, :map
    field :version, :integer, default: 1
    timestamps(type: :utc_datetime_usec)
  end
end
