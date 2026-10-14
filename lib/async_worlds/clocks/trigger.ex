defmodule AsyncWorlds.Clocks.Trigger do
  @moduledoc "Typed on-fill actions frozen for shared world/quest resolution and approved publication."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field :type, Ecto.Enum,
      values: [:notify_dm, :world_news, :start_clock, :set_flag, :unlock_quest]

    field :text, :string
    field :clock_id, :integer
    field :character_id, :integer
    field :quest_id, :integer
    field :key, :string
    field :flag, :map
  end

  def changeset(trigger, attrs) do
    trigger
    |> cast(attrs, [:type, :text, :clock_id, :character_id, :quest_id, :key, :flag])
    |> validate_keys(attrs)
    |> validate_required([:type])
    |> validate_payload()
  end

  defp validate_payload(changeset) do
    case get_field(changeset, :type) do
      type when type in [:notify_dm, :world_news] ->
        changeset
        |> validate_required([:text])
        |> validate_length(:text, max: 2000)
        |> validate_change(:text, fn :text, text ->
          if String.valid?(text) and not String.contains?(text, <<0>>),
            do: [],
            else: [text: "must be valid UTF-8 without NUL characters"]
        end)
        |> forbid_all([:clock_id, :character_id, :quest_id, :key, :flag])

      :start_clock ->
        changeset
        |> validate_required([:clock_id])
        |> validate_number(:clock_id,
          greater_than: 0,
          less_than_or_equal_to: 9_223_372_036_854_775_807
        )
        |> forbid_all([:text, :character_id, :quest_id, :key, :flag])

      :set_flag ->
        changeset
        |> validate_required([:character_id, :key, :flag])
        |> validate_number(:character_id,
          greater_than: 0,
          less_than_or_equal_to: 9_223_372_036_854_775_807
        )
        |> validate_change(:key, fn :key, key ->
          if AsyncWorlds.Characters.Flags.valid_key?(key), do: [], else: [key: "is invalid"]
        end)
        |> validate_change(:flag, fn :flag, flag ->
          if AsyncWorlds.Characters.Flags.valid_flag?(flag), do: [], else: [flag: "is invalid"]
        end)
        |> forbid_all([:text, :clock_id, :quest_id])

      :unlock_quest ->
        changeset
        |> validate_required([:character_id, :quest_id])
        |> validate_number(:character_id,
          greater_than: 0,
          less_than_or_equal_to: 9_223_372_036_854_775_807
        )
        |> validate_number(:quest_id,
          greater_than: 0,
          less_than_or_equal_to: 9_223_372_036_854_775_807
        )
        |> forbid_all([:text, :clock_id, :key, :flag])

      _ ->
        changeset
    end
  end

  def snapshot(trigger) do
    fields =
      if trigger.type in [:set_flag, :unlock_quest],
        do: [:type, :character_id, :quest_id, :key, :flag],
        else: [:type, :text, :clock_id]

    Map.take(trigger, fields)
  end

  defp validate_keys(changeset, attrs) do
    # Phoenix inputs_for adds this bookkeeping key; it is not game content.
    allowed = ~w(type text clock_id character_id quest_id key flag _persistent_id)

    if Enum.all?(Map.keys(attrs), &(to_string(&1) in allowed)),
      do: changeset,
      else: add_error(changeset, :type, "contains unsupported fields")
  end

  defp forbid_all(changeset, fields), do: Enum.reduce(fields, changeset, &forbid(&2, &1))

  defp forbid(changeset, field) do
    if get_field(changeset, field),
      do: add_error(changeset, field, "is not supported for this trigger"),
      else: changeset
  end
end
