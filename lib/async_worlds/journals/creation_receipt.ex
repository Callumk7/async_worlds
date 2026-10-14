defmodule AsyncWorlds.Journals.CreationReceipt do
  @moduledoc "Durable creation outcome. Never contains drafts, journal text or interaction tokens."
  use Ecto.Schema

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  schema "journal_creation_receipts" do
    field :campaign_id, :id
    field :character_id, :id
    field :request_id, :string
    field :actor_id, AsyncWorlds.Discord.Snowflake
    field :binding, :map
    field :origin, Ecto.Enum, values: [:player, :dm_persona, :dm]
    field :visibility, Ecto.Enum, values: [:private, :public]
    field :expires_at, :utc_datetime_usec

    field :state, Ecto.Enum,
      values: [:pending, :completed, :deleted, :canceled],
      default: :pending

    field :entry_id, :id
    timestamps(type: :utc_datetime_usec)
  end
end
