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

  alias AsyncWorlds.{Campaigns, DMAccess, Repo}
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

  @doc "Deletes a location within the authorized campaign."
  def delete_location(scope, location_id) do
    DMAccess.run(scope, fn campaign, _actor ->
      with {:ok, location} <- fetch(campaign.id, location_id), do: Repo.delete(location)
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
