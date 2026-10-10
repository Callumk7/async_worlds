defmodule AsyncWorldsWeb.LiveAuth do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView

  alias AsyncWorlds.WebAuth

  def on_mount(:ensure_dm, _params, session, socket) do
    token = session["web_session_token"]

    case WebAuth.authorize_session(token) do
      {:ok, scope} ->
        if connected?(socket) do
          Phoenix.PubSub.subscribe(AsyncWorlds.PubSub, WebAuth.session_topic(scope.session_id))
          Process.send_after(self(), :session_expired, expiry_delay(scope.expires_at))
        end

        socket =
          socket
          |> assign(:current_scope, scope)
          |> assign(:web_session_token, token)
          |> attach_hook(:fresh_dm_authorization, :handle_event, &authorize_event/3)
          |> attach_hook(:dm_session_messages, :handle_info, &session_message/2)
          |> attach_hook(:fresh_dm_navigation, :handle_params, &authorize_event/3)

        {:cont, socket}

      {:error, _reason} ->
        {:halt, redirect(socket, to: "/login")}
    end
  end

  defp authorize_event(_event, _params, socket) do
    case WebAuth.authorize_session(socket.assigns.web_session_token) do
      {:ok, scope} -> {:cont, assign(socket, :current_scope, scope)}
      {:error, _reason} -> {:halt, redirect(socket, to: "/login")}
    end
  end

  defp session_message(message, socket) when message in [:session_revoked, :session_expired],
    do: {:halt, redirect(socket, to: "/login")}

  defp session_message(_message, socket), do: {:cont, socket}

  defp expiry_delay(expires_at) do
    expires_at
    |> DateTime.diff(DateTime.utc_now(), :millisecond)
    |> max(0)
  end
end
