defmodule AsyncWorlds.Locations do
  @moduledoc """
  Campaign-scoped location CRUD for trusted DM interfaces.

  DM operations accept a scope containing `:campaign` and a verified
  `:discord_user_id`, as required by `AsyncWorlds.DMAccess`. Never build the
  actor identity from request parameters. Authorization is refreshed under
  the campaign row lock for every operation.

  Returns `{:ok, value}` or `{:error, reason}`. Validation errors return an
  `Ecto.Changeset`; missing or cross-campaign targets return `:not_found`.
  Campaign-readable projections are available for trusted guild-member
  interfaces. Callers must verify guild membership before using them. Names
  and descriptions are campaign-readable; locations have no tick effects.
  """
  import Ecto.Query

  alias AsyncWorlds.{Campaigns, DMAccess, LinkHistory, Repo}
  alias AsyncWorlds.Locations.Location

  @doc "Campaign-readable location summaries for trusted guild-member interfaces."
  def list_campaign_locations(guild_id) do
    with {:ok, campaign} <- Campaigns.fetch_campaign_by_guild(guild_id) do
      {:ok,
       Repo.all(
         from f in Location,
           where: f.campaign_id == ^campaign.id,
           order_by: f.id,
           select: %{id: f.id, name: f.name}
       )}
    end
  end

  @doc "Campaign-readable location detail; membership must be verified by the caller."
  def get_campaign_location(guild_id, location_id) do
    with {:ok, campaign} <- Campaigns.fetch_campaign_by_guild(guild_id),
         {:ok, location} <- fetch(campaign.id, location_id) do
      {:ok, Map.take(location, [:id, :name, :description])}
    end
  end

  @doc "Lists the current campaign's locations in creation order."
  def list_locations(scope) do
    DMAccess.run(scope, fn campaign, _actor ->
      {:ok, Repo.all(from f in Location, where: f.campaign_id == ^campaign.id, order_by: f.id)}
    end)
  end

  @doc "Fetches a location by ID within the authorized campaign."
  def get_location(scope, location_id) do
    DMAccess.run(scope, fn campaign, _actor -> fetch(campaign.id, location_id) end)
  end

  @doc "Creates a location; campaign ownership cannot be supplied in attrs."
  def create_location(scope, attrs) do
    DMAccess.run(scope, fn campaign, _actor ->
      %Location{campaign_id: campaign.id}
      |> Location.changeset(attrs)
      |> Repo.insert()
    end)
  end

  @doc "Updates editable fields on a campaign-owned location."
  def update_location(scope, location_id, attrs) do
    DMAccess.run(scope, fn campaign, _actor ->
      with {:ok, location} <- fetch(campaign.id, location_id) do
        location |> Location.changeset(attrs) |> Repo.update()
      end
    end)
  end

  @doc "Deletes an unlinked location. Clear its parent and children first."
  def delete_location(scope, location_id) do
    DMAccess.run(scope, fn campaign, _actor ->
      with {:ok, location} <- fetch(campaign.id, location_id) do
        if location.parent_id ||
             Repo.exists?(
               from l in Location,
                 where: l.campaign_id == ^campaign.id and l.parent_id == ^location.id
             ) do
          {:error, :location_linked}
        else
          location
          |> Ecto.Changeset.change()
          |> Ecto.Changeset.foreign_key_constraint(:parent_id, name: :locations_parent_id_fkey)
          |> Repo.delete()
        end
      end
    end)
  end

  @doc "Returns an authorized changeset for a new (nil ID) or existing location form."
  def change_location(scope, location_id \\ nil, attrs \\ %{}) do
    DMAccess.run(scope, fn campaign, _actor ->
      with {:ok, location} <- form_location(campaign.id, location_id) do
        {:ok, Location.changeset(location, attrs)}
      end
    end)
  end

  @doc "Sets/replaces the parent explicitly; nil clears it. No-op writes retain no history."
  def set_parent(scope, location_id, parent_id) do
    LinkHistory.transact(scope, fn campaign ->
      with {:ok, location} <- fetch(campaign.id, location_id),
           {:ok, parent} <- fetch_parent(campaign.id, parent_id),
           :ok <- validate_parent(campaign.id, location, parent),
           {:ok, updated} <-
             location |> Location.parent_changeset(parent && parent.id) |> Repo.update() do
        refs =
          Enum.uniq(Enum.reject([location.id, location.parent_id, updated.parent_id], &is_nil/1))

        change = %{
          kind: :location_containment,
          entity_refs: %{"location" => refs},
          before: containment_state(location),
          after: containment_state(updated)
        }

        {:ok, updated, [change]}
      end
    end)
  end

  @doc "Clears a location's parent through the same retained-history boundary."
  def clear_parent(scope, location_id), do: set_parent(scope, location_id, nil)

  @doc "Lists immediate children by ascending ID; nil lists campaign roots."
  def list_children(scope, parent_id \\ nil) do
    DMAccess.run(scope, fn campaign, _actor ->
      with {:ok, parent} <- fetch_parent(campaign.id, parent_id) do
        query = from l in Location, where: l.campaign_id == ^campaign.id, order_by: l.id

        query =
          if parent,
            do: where(query, [l], l.parent_id == ^parent.id),
            else: where(query, [l], is_nil(l.parent_id))

        {:ok, Repo.all(query)}
      end
    end)
  end

  @doc "Root-to-location breadcrumbs, including the location; bounded to 100 nodes."
  def breadcrumbs(scope, location_id) do
    DMAccess.run(scope, fn campaign, _actor ->
      with {:ok, location} <- fetch(campaign.id, location_id) do
        ancestors(campaign.id, location, MapSet.new(), [], 100)
      end
    end)
  end

  defp fetch_parent(_campaign_id, nil), do: {:ok, nil}
  defp fetch_parent(campaign_id, id), do: fetch(campaign_id, id)

  defp validate_parent(_campaign_id, _location, nil), do: :ok

  defp validate_parent(campaign_id, location, parent) do
    with {:ok, path} <- ancestors(campaign_id, parent, MapSet.new(), [], 100) do
      if Enum.any?(path, &(&1.id == location.id)),
        do: {:error, :location_cycle},
        else: :ok
    end
  end

  defp ancestors(campaign_id, location, seen, path, remaining) do
    cond do
      MapSet.member?(seen, location.id) ->
        {:error, :location_cycle}

      remaining == 0 ->
        {:error, :hierarchy_too_deep}

      is_nil(location.parent_id) ->
        {:ok, [location | path]}

      true ->
        with {:ok, parent} <- fetch(campaign_id, location.parent_id) do
          ancestors(
            campaign_id,
            parent,
            MapSet.put(seen, location.id),
            [location | path],
            remaining - 1
          )
        end
    end
  end

  defp containment_state(%Location{parent_id: nil}), do: nil

  defp containment_state(location),
    do: %{"location_id" => location.id, "parent_id" => location.parent_id}

  defp form_location(campaign_id, nil), do: {:ok, %Location{campaign_id: campaign_id}}
  defp form_location(campaign_id, location_id), do: fetch(campaign_id, location_id)

  defp fetch(campaign_id, location_id) do
    with {:ok, id} when is_integer(id) and id > 0 and id <= 9_223_372_036_854_775_807 <-
           Ecto.Type.cast(:id, location_id),
         %Location{} = location <- Repo.get_by(Location, campaign_id: campaign_id, id: id) do
      {:ok, location}
    else
      _ -> {:error, :not_found}
    end
  end
end
