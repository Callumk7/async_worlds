defmodule AsyncWorlds.Clocks.Trigger do
  @moduledoc "Typed world-only on-fill action. Starting unpauses an incomplete clock without resetting it."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field :type, Ecto.Enum, values: [:notify_dm, :world_news, :start_clock]
    field :text, :string
    field :clock_id, :integer
  end

  def changeset(trigger, attrs) do
    trigger
    |> cast(attrs, [:type, :text, :clock_id])
    |> validate_required([:type])
    |> validate_payload()
  end

  defp validate_payload(changeset) do
    case get_field(changeset, :type) do
      type when type in [:notify_dm, :world_news] ->
        changeset
        |> validate_required([:text])
        |> validate_length(:text, max: 2000)
        |> forbid(:clock_id)

      :start_clock ->
        changeset
        |> validate_required([:clock_id])
        |> validate_number(:clock_id, greater_than: 0)
        |> forbid(:text)

      _ ->
        changeset
    end
  end

  defp forbid(changeset, field) do
    if get_field(changeset, field),
      do: add_error(changeset, field, "is not supported for this trigger"),
      else: changeset
  end
end
