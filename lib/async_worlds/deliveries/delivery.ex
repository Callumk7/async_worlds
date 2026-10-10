defmodule AsyncWorlds.Deliveries.Delivery do
  @moduledoc "Persisted DM-only outbound intent and conservative send state."
  use Ecto.Schema
  import Ecto.Changeset

  schema "discord_deliveries" do
    belongs_to :campaign, AsyncWorlds.Campaigns.Campaign
    belongs_to :tick, AsyncWorlds.Ticks.Tick
    field :key, :string
    field :kind, Ecto.Enum, values: [:public, :private]
    field :recipient_id, :string
    field :content, :string

    field :status, Ecto.Enum,
      values: [:pending, :sending, :sent, :failed, :ambiguous],
      default: :pending

    field :generation, :integer, default: 0
    field :attempts, :integer, default: 0
    field :error_class, Ecto.Enum, values: [:retryable, :permanent, :ambiguous]
    field :last_error, :string
    field :message_id, :string
    field :channel_id, :string
    field :started_at, :utc_datetime_usec
    field :sent_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(delivery, attrs) do
    delivery
    |> cast(attrs, [:key, :kind, :recipient_id, :content])
    |> validate_required([:key, :kind, :recipient_id, :content])
    |> validate_length(:key, max: 200)
    |> validate_length(:content, max: 2000, count: :codepoints)
    |> validate_change(:recipient_id, fn :recipient_id, id ->
      case AsyncWorlds.Discord.Snowflake.cast(id) do
        {:ok, _} -> []
        _ -> [recipient_id: "must be a canonical Discord ID"]
      end
    end)
    |> unique_constraint([:campaign_id, :key])
    |> foreign_key_constraint(:campaign_id)
    |> foreign_key_constraint(:tick_id)
  end
end
