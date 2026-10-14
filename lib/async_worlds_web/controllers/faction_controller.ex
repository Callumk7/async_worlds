defmodule AsyncWorldsWeb.FactionController do
  use AsyncWorldsWeb, :controller

  alias AsyncWorlds.Factions
  alias AsyncWorldsWeb.ApiResponse

  @fields [:name, :description]
  @editable Enum.map(@fields, &Atom.to_string/1)

  def index(conn, _params) do
    with :ok <- query(conn),
         {:ok, factions} <- Factions.list_factions(conn.assigns.current_scope) do
      ApiResponse.success(conn, Enum.map(factions, &project/1))
    else
      {:error, reason} -> ApiResponse.domain_error(conn, reason, @fields)
    end
  end

  def show(conn, _params) do
    with :ok <- query(conn),
         {:ok, faction} <-
           Factions.get_faction(conn.assigns.current_scope, conn.path_params["id"]) do
      ApiResponse.success(conn, project(faction))
    else
      {:error, reason} -> ApiResponse.domain_error(conn, reason, @fields)
    end
  end

  def create(conn, _params) do
    with {:ok, attrs} <- body(conn, @editable),
         {:ok, faction} <- Factions.create_faction(conn.assigns.current_scope, attrs) do
      ApiResponse.success(conn, project(faction), status: 201)
    else
      {:error, reason} -> ApiResponse.domain_error(conn, reason, @fields)
    end
  end

  def update(conn, _params) do
    with {:ok, attrs} <- body(conn, @editable),
         {:ok, faction} <-
           Factions.update_faction(conn.assigns.current_scope, conn.path_params["id"], attrs) do
      ApiResponse.success(conn, project(faction))
    else
      {:error, reason} -> ApiResponse.domain_error(conn, reason, @fields)
    end
  end

  def delete(conn, _params) do
    with :ok <- query(conn),
         {:ok, _} <- delete_body(conn),
         {:ok, faction} <-
           Factions.delete_faction(conn.assigns.current_scope, conn.path_params["id"]) do
      ApiResponse.success(conn, project(faction))
    else
      {:error, reason} -> ApiResponse.domain_error(conn, reason, @fields)
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

  defp project(faction) do
    %{
      id: ApiResponse.id(faction.id),
      campaign_id: ApiResponse.id(faction.campaign_id),
      name: faction.name,
      description: faction.description,
      inserted_at: ApiResponse.timestamp(faction.inserted_at),
      updated_at: ApiResponse.timestamp(faction.updated_at)
    }
  end
end
