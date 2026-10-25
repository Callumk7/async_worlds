defmodule AsyncWorldsWeb.TensionController do
  use AsyncWorldsWeb, :controller

  alias AsyncWorlds.DM.Tensions
  alias AsyncWorlds.TensionDiscussions
  alias AsyncWorldsWeb.{ApiParams, ApiResponse}

  @fields [:name, :description, :audience]
  @editable Enum.map(@fields, &Atom.to_string/1)

  def index(conn, _params) do
    with :ok <- query(conn),
         {:ok, tensions} <- Tensions.list_tensions(conn.assigns.current_scope) do
      ApiResponse.success(conn, Enum.map(tensions, &project/1))
    else
      {:error, reason} -> ApiResponse.domain_error(conn, reason, @fields)
    end
  end

  def show(conn, _params) do
    scope = conn.assigns.current_scope

    with :ok <- query(conn),
         {:ok, tension} <- Tensions.get_tension(scope, conn.path_params["id"]),
         {:ok, clocks} <- Tensions.list_clocks(scope, tension.id),
         {:ok, discussion} <- discussion(scope, tension.id) do
      data =
        Map.merge(project(tension), %{
          clock_ids: Enum.map(clocks, &ApiResponse.id(&1.id)),
          discussion: discussion
        })

      ApiResponse.success(conn, data)
    else
      {:error, reason} -> ApiResponse.domain_error(conn, reason, @fields)
    end
  end

  def create(conn, _params) do
    with {:ok, attrs} <- body(conn, @editable),
         {:ok, tension} <- Tensions.create_tension(conn.assigns.current_scope, attrs, :http) do
      ApiResponse.success(conn, project(tension), status: 201)
    else
      {:error, reason} -> ApiResponse.domain_error(conn, reason, @fields)
    end
  end

  def update(conn, _params) do
    scope = conn.assigns.current_scope

    with {:ok, params} <- body(conn, ["revision" | @editable]),
         {:ok, revision} <- ApiParams.version(params["revision"]),
         {:ok, tension} <- Tensions.get_tension(scope, conn.path_params["id"]),
         :ok <- expected_revision(tension, revision),
         {:ok, updated} <-
           Tensions.edit_tension(scope, tension.id, Map.take(params, @editable), tension, :http) do
      ApiResponse.success(conn, project(updated))
    else
      {:error, reason} -> ApiResponse.domain_error(conn, reason, @fields)
    end
  end

  defp expected_revision(%{revision: revision}, revision), do: :ok
  defp expected_revision(_, _), do: {:error, :stale_tension}

  defp discussion(scope, id) do
    case TensionDiscussions.get(scope, id) do
      {:ok, discussion} ->
        {:ok,
         %{
           status: discussion.status,
           guild_id: ApiResponse.id(discussion.guild_id),
           thread_id: ApiResponse.id(discussion.thread_id)
         }}

      {:error, :not_found} ->
        {:ok, nil}

      {:error, reason} ->
        {:error, reason}
    end
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

  defp project(tension) do
    %{
      id: ApiResponse.id(tension.id),
      campaign_id: ApiResponse.id(tension.campaign_id),
      name: tension.name,
      description: tension.description,
      audience: Atom.to_string(tension.audience),
      status: Atom.to_string(tension.status),
      revision: tension.revision,
      inserted_at: ApiResponse.timestamp(tension.inserted_at),
      updated_at: ApiResponse.timestamp(tension.updated_at)
    }
  end
end
