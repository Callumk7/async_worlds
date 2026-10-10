defmodule AsyncWorldsWeb.Health do
  @moduledoc "Unauthenticated, bounded health probes. Never return database exception details."
  import Plug.Conn

  def init(opts), do: opts

  def call(%{method: method, request_path: "/health/live"} = conn, _)
      when method in ["GET", "HEAD"] do
    respond(conn, 200, %{status: "ok"})
  end

  def call(%{method: method, request_path: "/health/ready"} = conn, _)
      when method in ["GET", "HEAD"] do
    case database_status() do
      :ok -> respond(conn, 200, %{status: "ok", database: "ok"})
      :error -> respond(conn, 503, %{status: "unavailable", database: "unavailable"})
    end
  end

  def call(conn, _), do: conn

  def database_status do
    # Check both connectivity and the required application/queue schema. No SQL
    # or exception text is logged by the probe, even when the database is down.
    case Ecto.Adapters.SQL.query(
           AsyncWorlds.Repo,
           "SELECT 1 FROM campaigns CROSS JOIN oban_jobs LIMIT 0",
           [],
           timeout: 2_000,
           pool_timeout: 2_000,
           log: false
         ) do
      {:ok, _} -> :ok
      {:error, _} -> :error
    end
  rescue
    _ -> :error
  catch
    :exit, _ -> :error
  end

  defp respond(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(status, Jason.encode!(body))
    |> halt()
  end
end
