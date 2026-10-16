defmodule AsyncWorlds.LinkHistory do
  @moduledoc """
  Small, DM-only transaction/history boundary for trusted link writers.

  `transact/2` freshly authorizes under the campaign lock. Its callback receives
  the reloaded campaign and returns `{:ok, value, changes}` or `{:error, reason}`.
  Each change has `kind`, `entity_refs`, `before`, `after`, and optional `link_id`.
  The callback must read and mutate current links inside this transaction, derive
  states from those records (not request-supplied snapshots), and perform no
  external effects. This is not a generic HTTP mutation API.

  All link writes and change inserts commit together. Equal before/after states
  are omitted. Tick numbers are assigned here, never by callers: the open tick,
  otherwise the next tick, including while the preceding tick is resolving.
  See docs/link-history.md for the writer contract and DM query API.
  """
  import Ecto.Query
  alias AsyncWorlds.{DMAccess, Repo, Ticks}
  alias AsyncWorlds.LinkHistory.Change

  @entities %{
    "character" => AsyncWorlds.Characters.Character,
    "faction" => AsyncWorlds.Factions.Faction,
    "location" => AsyncWorlds.Locations.Location
  }
  @max_id 9_223_372_036_854_775_807
  @max_tick 2_147_483_647

  def transact(scope, fun) when is_function(fun, 1) do
    DMAccess.run(scope, fn campaign, actor ->
      with {:ok, number} <- tick_number(campaign) do
        case fun.(campaign) do
          {:ok, value, changes} when is_list(changes) and length(changes) <= 100 ->
            case record_changes(campaign.id, actor, number, changes) do
              :ok -> {:ok, value}
              {:error, reason} -> {:error, reason}
            end

          {:error, reason} ->
            {:error, reason}

          _ ->
            {:error, :invalid_changes}
        end
      end
    end)
  end

  def transact(_, _), do: {:error, :invalid_operation}

  @doc """
  DM-only changes in ascending ID order. Filters: `:tick_number` and
  `:entity` (`{"character" | "faction" | "location", id}`). Pagination uses
  `:after_id` (default 0) and `:limit` (default 50, maximum 100).
  Historical entity queries do not require the live entity to still exist.
  """
  def list_changes(scope, opts \\ []) do
    DMAccess.run(scope, fn campaign, _actor ->
      with {:ok, filters} <- filters(opts) do
        query = from c in Change, where: c.campaign_id == ^campaign.id

        query =
          if filters.tick, do: where(query, [c], c.tick_number == ^filters.tick), else: query

        query =
          if filters.entity do
            where(query, [c], fragment("? @> ?::jsonb", c.entity_refs, ^filters.entity))
          else
            query
          end

        rows =
          Repo.all(
            from c in query,
              where: c.id > ^filters.after_id,
              order_by: c.id,
              limit: ^(filters.limit + 1)
          )

        items = Enum.take(rows, filters.limit)
        more? = length(rows) > filters.limit
        cursor = if more?, do: List.last(items).id
        {:ok, %{items: items, more?: more?, next_cursor: cursor}}
      end
    end)
  end

  defp tick_number(campaign) do
    number =
      case Ticks.active_tick(campaign.id) do
        %{status: :open, number: number} -> number
        %{number: number} -> number + 1
        nil -> campaign.current_tick_number + 1
      end

    if number in 1..@max_tick, do: {:ok, number}, else: {:error, :tick_number_exhausted}
  end

  defp record_changes(campaign_id, actor, number, changes) do
    Enum.reduce_while(changes, :ok, fn attrs, :ok ->
      result = record(campaign_id, actor, number, attrs)
      if result == :ok, do: {:cont, :ok}, else: {:halt, result}
    end)
  end

  defp record(campaign_id, actor, number, attrs)
       when is_map(attrs) and (is_map_key(attrs, :before) or is_map_key(attrs, "before")) and
              (is_map_key(attrs, :after) or is_map_key(attrs, "after")) do
    changeset =
      Change.changeset(
        %Change{campaign_id: campaign_id, actor_id: actor, tick_number: number},
        attrs
      )

    with {:ok, change} <- Ecto.Changeset.apply_action(changeset, :insert),
         :ok <- validate_entities(campaign_id, change.entity_refs) do
      if change.before == change.after do
        :ok
      else
        case Repo.insert(changeset) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end
      end
    end
  end

  defp record(_, _, _, _), do: {:error, :invalid_changes}

  defp validate_entities(campaign_id, refs) do
    if Enum.all?(refs, fn {type, ids} ->
         schema = Map.fetch!(@entities, type)

         count =
           Repo.aggregate(
             from(e in schema, where: e.campaign_id == ^campaign_id and e.id in ^ids),
             :count
           )

         count == length(ids)
       end),
       do: :ok,
       else: {:error, :not_found}
  end

  defp filters(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and
         Enum.all?(Keyword.keys(opts), &(&1 in [:tick_number, :entity, :after_id, :limit])) do
      with {:ok, tick} <- optional_tick(Keyword.get(opts, :tick_number)),
           {:ok, entity} <- entity_filter(Keyword.get(opts, :entity)),
           {:ok, after_id} <- cast_number(Keyword.get(opts, :after_id, 0), 0, @max_id),
           {:ok, limit} <- cast_number(Keyword.get(opts, :limit, 50), 1, 100) do
        {:ok, %{tick: tick, entity: entity, after_id: after_id, limit: limit}}
      end
    else
      {:error, :invalid_filters}
    end
  end

  defp filters(_), do: {:error, :invalid_filters}
  defp optional_tick(nil), do: {:ok, nil}
  defp optional_tick(value), do: cast_number(value, 1, @max_tick)
  defp entity_filter(nil), do: {:ok, nil}

  defp entity_filter({type, value}) when is_map_key(@entities, type) do
    with {:ok, id} <- cast_number(value, 1, @max_id), do: {:ok, %{type => [id]}}
  end

  defp entity_filter(_), do: {:error, :invalid_filters}

  defp cast_number(value, min, max) do
    case Ecto.Type.cast(:id, value) do
      {:ok, number} when is_integer(number) and number >= min and number <= max -> {:ok, number}
      _ -> {:error, :invalid_filters}
    end
  end
end
