defmodule AsyncWorldsWeb.ApiAuth do
  @moduledoc """
  Shared DM bearer authentication for /api requests, before body parsing.

  Campaign routes use /api/campaigns/:guild_id/... and receive a freshly
  authorized current_scope. Other API routes receive the verified DM identity
  with no selected campaign; they must authorize any campaign they access.
  Browser sessions and request-supplied actor identities are never credentials.
  """
  import Plug.Conn
  alias AsyncWorlds.Campaigns
  alias AsyncWorlds.Discord.Snowflake

  def init(opts), do: opts

  def call(%{path_info: ["api" | _]} = conn, _opts) do
    with {:ok, dm_id} <- authenticate(conn),
         {:ok, campaign} <- campaign(conn.path_info, dm_id) do
      assign(conn, :current_scope, %{discord_user_id: dm_id, campaign: campaign})
    else
      {:error, :unauthenticated} ->
        conn |> AsyncWorldsWeb.ApiResponse.error(:unauthenticated) |> halt()

      {:error, _} ->
        conn |> AsyncWorldsWeb.ApiResponse.error(:not_found) |> halt()
    end
  end

  def call(conn, _opts), do: conn

  defp authenticate(conn) do
    config = Application.get_env(:async_worlds, :dm_api, [])
    token = Keyword.get(config, :token)

    with true <- is_binary(token) and byte_size(token) >= 32,
         {:ok, dm_id} <- Snowflake.cast(Keyword.get(config, :dm_user_id)),
         [header] <- get_req_header(conn, "authorization"),
         [scheme, supplied] <- String.split(header, " ", parts: 2),
         true <- String.downcase(scheme) == "bearer",
         true <-
           Plug.Crypto.secure_compare(
             :crypto.hash(:sha256, supplied),
             :crypto.hash(:sha256, token)
           ) do
      {:ok, dm_id}
    else
      _ -> {:error, :unauthenticated}
    end
  end

  defp campaign(["api", "campaigns", guild | _], dm_id),
    do: Campaigns.authorize_dm(guild, dm_id)

  defp campaign(_, _), do: {:ok, nil}
end
