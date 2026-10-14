defmodule AsyncWorldsWeb.ApiRequest do
  @moduledoc "Strict shared request validation for DM HTTP resources."
  import Plug.Conn, only: [get_req_header: 2]
  alias AsyncWorldsWeb.ApiParams

  def query(conn, allowed) do
    if Map.keys(conn.query_params) -- allowed == [], do: :ok, else: {:error, :invalid_parameters}
  end

  def body(conn, allowed) do
    with :ok <- query(conn, []),
         [type] <- get_req_header(conn, "content-type"),
         "application/json" <- type |> String.split(";") |> hd() |> String.trim(),
         params when is_map(params) <- conn.body_params,
         true <- Map.keys(params) -- allowed == [] do
      {:ok, params}
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :invalid_parameters}
      _ -> {:error, :unsupported_media_type}
    end
  end

  def resource_id(conn, key \\ "id") do
    case ApiParams.id(conn.path_params[key]) do
      {:ok, id} -> {:ok, id}
      _ -> {:error, :not_found}
    end
  end
end
