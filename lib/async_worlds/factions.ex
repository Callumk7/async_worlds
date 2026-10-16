defmodule AsyncWorlds.Factions do
  @moduledoc """
  Campaign-scoped faction CRUD for trusted DM interfaces.

  DM operations accept a scope containing `:campaign` and a verified
  `:discord_user_id`, as required by `AsyncWorlds.DMAccess`. Never build the
  actor identity from request parameters. Authorization is refreshed under
  the campaign row lock for every operation.

  Returns `{:ok, value}` or `{:error, reason}`. Validation errors return an
  `Ecto.Changeset`; missing or cross-campaign targets return `:not_found`.
  Campaign-readable projections are available for trusted guild-member
  interfaces. Callers must verify guild membership before using them. Names
  and descriptions are campaign-readable; factions have no tick effects.
  """
  import Ecto.Query

  alias AsyncWorlds.{Campaigns, DMAccess, Repo}
  alias AsyncWorlds.Factions.{Faction, Membership}

  @doc "Campaign-readable faction summaries for trusted guild-member interfaces."
  def list_campaign_factions(guild_id) do
    with {:ok, campaign} <- Campaigns.fetch_campaign_by_guild(guild_id) do
      {:ok,
       Repo.all(
         from f in Faction,
           where: f.campaign_id == ^campaign.id,
           order_by: f.id,
           select: %{id: f.id, name: f.name}
       )}
    end
  end

  @doc "Campaign-readable faction detail; membership must be verified by the caller."
  def get_campaign_faction(guild_id, faction_id) do
    with {:ok, campaign} <- Campaigns.fetch_campaign_by_guild(guild_id),
         {:ok, faction} <- fetch(campaign.id, faction_id) do
      {:ok, Map.take(faction, [:id, :name, :description])}
    end
  end

  @doc "Lists the current campaign's factions in creation order."
  def list_factions(scope) do
    DMAccess.run(scope, fn campaign, _actor ->
      {:ok, Repo.all(from f in Faction, where: f.campaign_id == ^campaign.id, order_by: f.id)}
    end)
  end

  @doc "Fetches a faction by ID within the authorized campaign."
  def get_faction(scope, faction_id) do
    DMAccess.run(scope, fn campaign, _actor -> fetch(campaign.id, faction_id) end)
  end

  @doc "Creates a faction; campaign ownership cannot be supplied in attrs."
  def create_faction(scope, attrs) do
    DMAccess.run(scope, fn campaign, _actor ->
      %Faction{campaign_id: campaign.id}
      |> Faction.changeset(attrs)
      |> Repo.insert()
    end)
  end

  @doc "Updates editable fields on a campaign-owned faction."
  def update_faction(scope, faction_id, attrs) do
    DMAccess.run(scope, fn campaign, _actor ->
      with {:ok, faction} <- fetch(campaign.id, faction_id) do
        faction |> Faction.changeset(attrs) |> Repo.update()
      end
    end)
  end

  @doc "Deletes an unreferenced faction; explicitly remove current memberships first."
  def delete_faction(scope, faction_id) do
    DMAccess.run(scope, fn campaign, _actor ->
      with {:ok, faction} <- fetch(campaign.id, faction_id) do
        if Repo.exists?(
             from m in Membership,
               where: m.campaign_id == ^campaign.id and m.faction_id == ^faction.id
           ) do
          {:error, :faction_has_memberships}
        else
          Repo.delete(faction)
        end
      end
    end)
  end

  @doc "Returns an authorized changeset for a new (nil ID) or existing faction form."
  def change_faction(scope, faction_id \\ nil, attrs \\ %{}) do
    DMAccess.run(scope, fn campaign, _actor ->
      with {:ok, faction} <- form_faction(campaign.id, faction_id) do
        {:ok, Faction.changeset(faction, attrs)}
      end
    end)
  end

  defp form_faction(campaign_id, nil), do: {:ok, %Faction{campaign_id: campaign_id}}
  defp form_faction(campaign_id, faction_id), do: fetch(campaign_id, faction_id)

  defp fetch(campaign_id, faction_id) do
    with {:ok, id} when is_integer(id) and id > 0 and id <= 9_223_372_036_854_775_807 <-
           Ecto.Type.cast(:id, faction_id),
         %Faction{} = faction <- Repo.get_by(Faction, campaign_id: campaign_id, id: id) do
      {:ok, faction}
    else
      _ -> {:error, :not_found}
    end
  end
end
