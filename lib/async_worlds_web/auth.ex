defmodule AsyncWorldsWeb.Auth do
  @moduledoc "HTTP and LiveView DM authorization boundaries."

  import Phoenix.Controller
  import Plug.Conn

  alias AsyncWorlds.WebAuth

  def init(action), do: action
  def call(conn, :fetch_current_scope), do: fetch_current_scope(conn, [])
  def call(conn, :require_authenticated_dm), do: require_authenticated_dm(conn, [])

  def fetch_current_scope(conn, _opts) do
    case WebAuth.authorize_session(get_session(conn, :web_session_token)) do
      {:ok, scope} -> assign(conn, :current_scope, scope)
      {:error, _reason} -> assign(conn, :current_scope, nil)
    end
  end

  def require_authenticated_dm(%{assigns: %{current_scope: nil}} = conn, _opts) do
    conn
    |> put_flash(:error, "Sign in with the configured DM account to continue.")
    |> redirect(to: "/login")
    |> halt()
  end

  def require_authenticated_dm(conn, _opts), do: conn
end
