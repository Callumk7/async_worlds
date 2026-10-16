defmodule AsyncWorlds.Memberships do
  @moduledoc """
  Focused, DM-only current memberships and retained state changes.

  All operations freshly authorize a trusted DM scope under the campaign lock.
  Endpoints are campaign-scoped and immutable; only optional role metadata is
  editable. Roles grant no permissions or gameplay effects. Mutations share the
  LinkHistory transaction boundary, without updating character generations or
  adopting gameplay tick locks. See docs/memberships.md.
  """
  import Ecto.Query

  alias AsyncWorlds.{DMAccess, LinkHistory, Repo}
  alias AsyncWorlds.Characters.Character
  alias AsyncWorlds.Factions.{Faction, Membership}

  @doc "Joins a character to a faction. A duplicate pair returns a validation changeset."
  def join(scope, character_id, faction_id, attrs \\ %{}) do
    LinkHistory.transact(scope, fn campaign ->
      with {:ok, character} <- fetch(Character, campaign.id, character_id),
           {:ok, faction} <- fetch(Faction, campaign.id, faction_id),
           {:ok, membership} <-
             %Membership{
               campaign_id: campaign.id,
               character_id: character.id,
               faction_id: faction.id
             }
             |> Membership.changeset(attrs)
             |> Repo.insert() do
        {:ok, membership, [change(nil, membership)]}
      end
    end)
  end

  @doc "Edits only the role on a current membership; unchanged roles retain no history."
  def edit_role(scope, membership_id, attrs) do
    LinkHistory.transact(scope, fn campaign ->
      with {:ok, membership} <- fetch(Membership, campaign.id, membership_id),
           {:ok, updated} <- membership |> Membership.changeset(attrs) |> Repo.update() do
        {:ok, updated, [change(membership, updated)]}
      end
    end)
  end

  @doc "Removes a current membership while retaining history indexed by both endpoints."
  def leave(scope, membership_id) do
    LinkHistory.transact(scope, fn campaign ->
      with {:ok, membership} <- fetch(Membership, campaign.id, membership_id),
           {:ok, deleted} <- Repo.delete(membership) do
        {:ok, deleted, [change(membership, nil)]}
      end
    end)
  end

  @doc "Current faction members by ascending membership ID, with both endpoints preloaded."
  def list_faction_members(scope, faction_id),
    do: list(scope, Faction, :faction_id, faction_id)

  @doc "Current character affiliations by ascending membership ID, with both endpoints preloaded."
  def list_character_affiliations(scope, character_id),
    do: list(scope, Character, :character_id, character_id)

  defp list(scope, schema, field, id) do
    DMAccess.run(scope, fn campaign, _actor ->
      with {:ok, endpoint} <- fetch(schema, campaign.id, id) do
        {:ok,
         Repo.all(
           from m in Membership,
             where: m.campaign_id == ^campaign.id and field(m, ^field) == ^endpoint.id,
             order_by: m.id,
             preload: [:character, :faction]
         )}
      end
    end)
  end

  defp fetch(schema, campaign_id, value) do
    with {:ok, id} when is_integer(id) and id > 0 and id <= 9_223_372_036_854_775_807 <-
           Ecto.Type.cast(:id, value),
         record when not is_nil(record) <- Repo.get_by(schema, campaign_id: campaign_id, id: id) do
      {:ok, record}
    else
      _ -> {:error, :not_found}
    end
  end

  defp change(before, after_state) do
    membership = after_state || before

    %{
      kind: :faction_membership,
      link_id: membership.id,
      entity_refs: %{
        "character" => [membership.character_id],
        "faction" => [membership.faction_id]
      },
      before: state(before),
      after: state(after_state)
    }
  end

  defp state(nil), do: nil

  defp state(membership),
    do: %{
      "character_id" => membership.character_id,
      "faction_id" => membership.faction_id,
      "role" => membership.role
    }
end
