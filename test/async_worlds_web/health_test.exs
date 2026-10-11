defmodule AsyncWorldsWeb.HealthTest do
  use AsyncWorldsWeb.ConnCase, async: false

  test "liveness and database readiness do not require a session", %{conn: conn} do
    live = get(conn, "/health/live")
    assert json_response(live, 200) == %{"status" => "ok"}
    assert get_resp_header(live, "cache-control") == ["no-store"]
    ready = get(conn, "/health/ready")
    assert json_response(ready, 200) == %{"status" => "ok", "database" => "ok"}
  end

  test "missing queue schema is unavailable with no exception or connection details", %{
    conn: conn
  } do
    Ecto.Adapters.SQL.query!(
      AsyncWorlds.Repo,
      "ALTER TABLE oban_jobs RENAME TO health_hidden_jobs"
    )

    ready = get(conn, "/health/ready")
    assert json_response(ready, 503) == %{"status" => "unavailable", "database" => "unavailable"}
    assert json_response(get(conn, "/health/live"), 200) == %{"status" => "ok"}
  end
end
