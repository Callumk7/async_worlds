defmodule AsyncWorldsWeb.AuthController do
  use AsyncWorldsWeb, :controller

  alias AsyncWorlds.WebAuth

  require Logger

  def new(conn, _params) do
    case WebAuth.begin_oauth() do
      {:ok, state, authorization_url} ->
        conn
        |> put_session(:oauth_state, state)
        |> redirect(external: authorization_url)

      {:error, _reason} ->
        Logger.warning("Discord OAuth start failed")

        conn
        |> put_flash(:error, "Discord sign-in is temporarily unavailable.")
        |> redirect(to: ~p"/login")
    end
  end

  def callback(conn, %{"error" => _error} = params) do
    _ = WebAuth.consume_state(params["state"], get_session(conn, :oauth_state))
    authentication_failed(conn)
  end

  def callback(conn, %{"code" => code, "state" => state}) do
    expected_state = get_session(conn, :oauth_state)

    case WebAuth.complete_oauth(state, expected_state, code) do
      {:ok, token, _scope} ->
        conn
        |> delete_session(:oauth_state)
        |> configure_session(renew: true)
        |> put_session(:web_session_token, token)
        |> redirect(to: ~p"/dashboard")

      {:error, reason} ->
        Logger.warning("Discord OAuth callback failed", discord_stage: safe_stage(reason))
        authentication_failed(conn)
    end
  end

  def callback(conn, _params), do: authentication_failed(conn)

  def delete(conn, _params) do
    WebAuth.revoke_session(get_session(conn, :web_session_token))

    conn
    |> configure_session(drop: true)
    |> put_flash(:info, "You have been signed out.")
    |> redirect(to: ~p"/login")
  end

  defp authentication_failed(conn) do
    conn
    |> delete_session(:oauth_state)
    |> delete_session(:web_session_token)
    |> put_flash(:error, "Discord sign-in could not be completed. Please try again.")
    |> redirect(to: ~p"/login")
  end

  defp safe_stage(:invalid_state), do: "state"
  defp safe_stage(:token_exchange_failed), do: "token_exchange"
  defp safe_stage(:profile_failed), do: "profile"
  defp safe_stage(:unauthorized), do: "authorization"
  defp safe_stage(:ambiguous_campaign), do: "authorization"
  defp safe_stage(_), do: "session"
end
