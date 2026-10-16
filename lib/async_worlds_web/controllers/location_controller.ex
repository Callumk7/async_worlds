defmodule AsyncWorldsWeb.LocationController do
  use AsyncWorldsWeb, :controller

  alias AsyncWorlds.Locations
  alias AsyncWorldsWeb.ApiResponse

  @fields [:name, :description, :kind]
  @editable Enum.map(@fields, &Atom.to_string/1)

  def index(conn, _params) do
    with :ok <- query(conn),
         {:ok, locations} <- Locations.list_locations(conn.assigns.current_scope) do
      ApiResponse.success(conn, Enum.map(locations, &project/1))
    else
      {:error, reason} -> ApiResponse.domain_error(conn, reason, @fields)
    end
  end

  def show(conn, _params) do
    with :ok <- query(conn),
         {:ok, location} <-
           Locations.get_location(conn.assigns.current_scope, conn.path_params["id"]) do
      ApiResponse.success(conn, project(location))
    else
      {:error, reason} -> ApiResponse.domain_error(conn, reason, @fields)
    end
  end

  def create(conn, _params) do
    with {:ok, attrs} <- body(conn, @editable),
         {:ok, location} <- Locations.create_location(conn.assigns.current_scope, attrs) do
      ApiResponse.success(conn, project(location), status: 201)
    else
      {:error, reason} -> ApiResponse.domain_error(conn, reason, @fields)
    end
  end

  def update(conn, _params) do
    with {:ok, attrs} <- body(conn, @editable),
         {:ok, location} <-
           Locations.update_location(conn.assigns.current_scope, conn.path_params["id"], attrs) do
      ApiResponse.success(conn, project(location))
    else
      {:error, reason} -> ApiResponse.domain_error(conn, reason, @fields)
    end
  end

  def delete(conn, _params) do
    with :ok <- query(conn),
         {:ok, _} <- delete_body(conn),
         {:ok, location} <-
           Locations.delete_location(conn.assigns.current_scope, conn.path_params["id"]) do
      ApiResponse.success(conn, project(location))
    else
      {:error, reason} -> ApiResponse.domain_error(conn, reason, @fields)
    end
  end

  def roots(conn, _params), do: hierarchy(conn, :roots)
  def children(conn, _params), do: hierarchy(conn, :children)
  def breadcrumbs(conn, _params), do: hierarchy(conn, :breadcrumbs)

  defp hierarchy(conn, operation) do
    scope = conn.assigns.current_scope
    id = conn.path_params["id"]

    with :ok <- query(conn),
         {:ok, locations} <-
           (case operation do
              :roots -> Locations.list_children(scope)
              :children -> Locations.list_children(scope, id)
              :breadcrumbs -> Locations.breadcrumbs(scope, id)
            end) do
      ApiResponse.success(conn, Enum.map(locations, &project/1))
    else
      {:error, reason} -> ApiResponse.domain_error(conn, reason)
    end
  end

  def parent(conn, _params) do
    with {:ok, attrs} <- body(conn, ["parent_id"]),
         {:ok, parent_id} <- Map.fetch(attrs, "parent_id"),
         {:ok, location} <-
           Locations.set_parent(conn.assigns.current_scope, conn.path_params["id"], parent_id) do
      ApiResponse.success(conn, project(location))
    else
      :error -> ApiResponse.error(conn, :invalid_parameters)
      {:error, reason} -> ApiResponse.domain_error(conn, reason)
    end
  end

  defp delete_body(conn) do
    if conn.body_params == %{} and get_req_header(conn, "content-type") == [],
      do: {:ok, %{}},
      else: body(conn, [])
  end

  defp query(conn) do
    if conn.query_params == %{}, do: :ok, else: {:error, :invalid_parameters}
  end

  defp body(conn, allowed) do
    with :ok <- query(conn),
         [content_type] <- get_req_header(conn, "content-type"),
         "application/json" <- content_type |> String.split(";") |> hd() |> String.trim(),
         params when is_map(params) <- conn.body_params,
         true <- Map.keys(params) -- allowed == [] do
      {:ok, params}
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :invalid_parameters}
      _ -> {:error, :unsupported_media_type}
    end
  end

  defp project(location) do
    %{
      id: ApiResponse.id(location.id),
      campaign_id: ApiResponse.id(location.campaign_id),
      name: location.name,
      description: location.description,
      kind: location.kind,
      parent_id: ApiResponse.id(location.parent_id),
      inserted_at: ApiResponse.timestamp(location.inserted_at),
      updated_at: ApiResponse.timestamp(location.updated_at)
    }
  end
end
