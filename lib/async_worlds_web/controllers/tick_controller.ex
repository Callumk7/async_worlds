defmodule AsyncWorldsWeb.TickController do
  use AsyncWorldsWeb, :controller

  alias AsyncWorlds.DM.Ticks
  alias AsyncWorldsWeb.{ApiParams, ApiResponse}

  def status(conn, _params) do
    with :ok <- query(conn),
         {:ok, tick} <- Ticks.status(conn.assigns.current_scope) do
      ApiResponse.success(conn, project_tick(tick))
    else
      {:error, reason} -> ApiResponse.domain_error(conn, reason)
    end
  end

  def open(conn, _params) do
    with :ok <- body(conn),
         {:ok, tick} <- Ticks.open_tick(conn.assigns.current_scope) do
      ApiResponse.success(conn, project_tick(tick), status: 201)
    else
      {:error, reason} -> ApiResponse.domain_error(conn, reason)
    end
  end

  def close(conn, _params) do
    with :ok <- body(conn),
         {:ok, id} <- resource_id(conn),
         {:ok, %{tick: tick}} <- Ticks.close_tick(conn.assigns.current_scope, id) do
      ApiResponse.success(conn, project_tick(tick), status: 202)
    else
      {:error, reason} -> ApiResponse.domain_error(conn, reason)
    end
  end

  def readiness(conn, _params) do
    with :ok <- query(conn),
         {:ok, id} <- resource_id(conn),
         {:ok, roster} <- Ticks.readiness_roster(conn.assigns.current_scope, id) do
      ApiResponse.success(conn, project_readiness(id, roster))
    else
      {:error, reason} -> ApiResponse.domain_error(conn, reason)
    end
  end

  def roster(conn, _params) do
    with :ok <- query(conn),
         {:ok, id} <- resource_id(conn),
         {:ok, roster} <- Ticks.readiness_roster(conn.assigns.current_scope, id) do
      data = Map.put(project_readiness(id, roster), :rows, Enum.map(roster.rows, &project_row/1))
      ApiResponse.success(conn, data)
    else
      {:error, reason} -> ApiResponse.domain_error(conn, reason)
    end
  end

  def remind(conn, _params) do
    with :ok <- body(conn),
         {:ok, key} <- ApiParams.idempotency_key(conn),
         {:ok, count} <- Ticks.remind(conn.assigns.current_scope, key) do
      ApiResponse.success(conn, %{missing: count}, status: 202)
    else
      {:error, reason} -> ApiResponse.domain_error(conn, reason)
    end
  end

  defp resource_id(conn) do
    case ApiParams.id(conn.path_params["id"]) do
      {:ok, id} -> {:ok, id}
      _ -> {:error, :not_found}
    end
  end

  defp query(conn) do
    if conn.query_params == %{}, do: :ok, else: {:error, :invalid_parameters}
  end

  defp body(conn) do
    with :ok <- query(conn),
         [content_type] <- get_req_header(conn, "content-type"),
         "application/json" <- content_type |> String.split(";") |> hd() |> String.trim(),
         params when is_map(params) <- conn.body_params,
         true <- params == %{} do
      :ok
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :invalid_parameters}
      _ -> {:error, :unsupported_media_type}
    end
  end

  defp project_tick(nil), do: nil

  defp project_tick(tick) do
    %{
      id: ApiResponse.id(tick.id),
      campaign_id: ApiResponse.id(tick.campaign_id),
      number: tick.number,
      status: Atom.to_string(tick.status),
      opened_at: ApiResponse.timestamp(tick.opened_at),
      closed_at: ApiResponse.timestamp(tick.closed_at),
      reviewed_at: ApiResponse.timestamp(tick.reviewed_at),
      published_at: ApiResponse.timestamp(tick.published_at)
    }
  end

  defp project_readiness(id, roster) do
    %{
      tick_id: ApiResponse.id(id),
      tick_number: roster.tick_number,
      frozen: roster.frozen,
      counts: Map.take(roster.counts, [:active, :submitted, :missing])
    }
  end

  defp project_row(row) do
    %{
      character_id: ApiResponse.id(row.character_id),
      name: row.name,
      discord_user_id: ApiResponse.id(row.discord_user_id),
      unassigned: row.unassigned,
      invalidated: row.invalidated,
      quest_name: row.quest_name,
      node_id: row.node_id,
      state: Atom.to_string(row.state)
    }
  end
end
