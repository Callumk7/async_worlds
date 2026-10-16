defmodule AsyncWorlds.LinkHistory.Change do
  @moduledoc "A retained, DM-only link transition associated with a campaign tick number."
  use Ecto.Schema
  import Ecto.Changeset

  schema "link_changes" do
    belongs_to :campaign, AsyncWorlds.Campaigns.Campaign
    field :tick_number, :integer
    field :kind, Ecto.Enum, values: [:faction_membership, :location_containment]
    field :link_id, :id
    field :entity_refs, :map
    field :before, :map
    field :after, :map
    field :actor_id, :string
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc false
  def changeset(change, attrs) do
    change
    |> cast(attrs, [:kind, :link_id, :entity_refs, :before, :after])
    |> validate_required([:kind, :entity_refs])
    |> validate_number(:link_id,
      greater_than: 0,
      less_than_or_equal_to: 9_223_372_036_854_775_807
    )
    |> validate_refs()
    |> validate_change(:before, &validate_state/2)
    |> validate_change(:after, &validate_state/2)
    |> foreign_key_constraint(:campaign_id)
    |> check_constraint(:tick_number, name: :link_change_tick_positive)
    |> check_constraint(:kind, name: :link_change_kind_valid)
    |> check_constraint(:entity_refs, name: :link_change_refs_object)
    |> check_constraint(:after, name: :link_change_state_valid)
  end

  defp validate_refs(changeset) do
    refs = get_field(changeset, :entity_refs)

    valid? =
      case {get_field(changeset, :kind), refs} do
        {:faction_membership, %{"character" => [character], "faction" => [faction]}}
        when map_size(refs) == 2 ->
          valid_id?(character) and valid_id?(faction)

        {:location_containment, %{"location" => ids}} when map_size(refs) == 1 and is_list(ids) ->
          length(ids) in 1..3 and Enum.all?(ids, &valid_id?/1) and ids == Enum.uniq(ids)

        _ ->
          false
      end

    if valid?,
      do: changeset,
      else: add_error(changeset, :entity_refs, "must identify the link's endpoints")
  end

  defp valid_id?(id), do: is_integer(id) and id > 0 and id <= 9_223_372_036_854_775_807

  defp validate_state(field, state) do
    if json_value?(state, 0) and byte_size(Jason.encode!(state)) <= 16_384,
      do: [],
      else: [{field, "must be a string-keyed JSON object of at most 16384 bytes and 8 levels"}]
  end

  defp json_value?(_, depth) when depth > 8, do: false
  defp json_value?(nil, _), do: true
  defp json_value?(value, _) when is_boolean(value) or is_integer(value), do: true

  defp json_value?(value, _) when is_binary(value),
    do: String.valid?(value) and not String.contains?(value, <<0>>)

  defp json_value?(value, depth) when is_list(value),
    do: Enum.all?(value, &json_value?(&1, depth + 1))

  defp json_value?(value, depth) when is_map(value) and not is_struct(value),
    do:
      Enum.all?(value, fn {key, item} ->
        is_binary(key) and json_value?(key, depth + 1) and json_value?(item, depth + 1)
      end)

  defp json_value?(_, _), do: false
end
