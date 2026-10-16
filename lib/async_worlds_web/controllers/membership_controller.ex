defmodule AsyncWorldsWeb.MembershipController do
  use AsyncWorldsWeb, :controller

  alias AsyncWorlds.Memberships
  alias AsyncWorldsWeb.{ApiRequest, ApiResponse}

  def faction_members(conn, _params), do: list(conn, :faction)
  def character_affiliations(conn, _params), do: list(conn, :character)

  defp list(conn, endpoint) do
    scope = conn.assigns.current_scope
    id = conn.path_params["id"]

    with :ok <- ApiRequest.query(conn, []),
         {:ok, memberships} <-
           (case endpoint do
              :faction -> Memberships.list_faction_members(scope, id)
              :character -> Memberships.list_character_affiliations(scope, id)
            end) do
      ApiResponse.success(conn, Enum.map(memberships, &project/1))
    else
      {:error, reason} -> ApiResponse.domain_error(conn, reason)
    end
  end

  def create(conn, _params) do
    with {:ok, attrs} <- ApiRequest.body(conn, ~w(character_id faction_id role)),
         {:ok, membership} <-
           Memberships.join(
             conn.assigns.current_scope,
             attrs["character_id"],
             attrs["faction_id"],
             Map.take(attrs, ["role"])
           ) do
      ApiResponse.success(conn, project(membership), status: 201)
    else
      {:error, reason} -> ApiResponse.domain_error(conn, reason, [:role])
    end
  end

  def update(conn, _params) do
    with {:ok, attrs} <- ApiRequest.body(conn, ["role"]),
         {:ok, membership} <-
           Memberships.edit_role(conn.assigns.current_scope, conn.path_params["id"], attrs) do
      ApiResponse.success(conn, project(membership))
    else
      {:error, reason} -> ApiResponse.domain_error(conn, reason, [:role])
    end
  end

  def delete(conn, _params) do
    with :ok <- ApiRequest.query(conn, []),
         {:ok, _} <- delete_body(conn),
         {:ok, membership} <-
           Memberships.leave(conn.assigns.current_scope, conn.path_params["id"]) do
      ApiResponse.success(conn, project(membership))
    else
      {:error, reason} -> ApiResponse.domain_error(conn, reason)
    end
  end

  defp delete_body(conn) do
    if conn.body_params == %{} and get_req_header(conn, "content-type") == [],
      do: {:ok, %{}},
      else: ApiRequest.body(conn, [])
  end

  defp project(membership) do
    %{
      id: ApiResponse.id(membership.id),
      campaign_id: ApiResponse.id(membership.campaign_id),
      character_id: ApiResponse.id(membership.character_id),
      faction_id: ApiResponse.id(membership.faction_id),
      role: membership.role,
      inserted_at: ApiResponse.timestamp(membership.inserted_at),
      updated_at: ApiResponse.timestamp(membership.updated_at)
    }
  end
end
