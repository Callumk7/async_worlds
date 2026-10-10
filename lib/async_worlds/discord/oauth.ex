defmodule AsyncWorlds.Discord.OAuth do
  @moduledoc "A narrow Req-backed client for Discord's OAuth code exchange and identity endpoint."

  alias AsyncWorlds.Discord.Snowflake

  @authorize_url "https://discord.com/oauth2/authorize"

  def authorization_url(state) do
    config = config!()

    @authorize_url <>
      "?" <>
      URI.encode_query(%{
        "client_id" => config[:client_id],
        "redirect_uri" => config[:redirect_uri],
        "response_type" => "code",
        "scope" => "identify",
        "state" => state
      })
  end

  def exchange_code(code) when is_binary(code) do
    config = config!()

    request(config)
    |> Req.post(
      url: config[:token_url],
      form: [
        grant_type: "authorization_code",
        code: code,
        client_id: config[:client_id],
        client_secret: config[:client_secret],
        redirect_uri: config[:redirect_uri]
      ]
    )
    |> case do
      {:ok, %{status: 200, body: %{"access_token" => token}}} when is_binary(token) ->
        {:ok, token}

      _ ->
        {:error, :token_exchange_failed}
    end
  rescue
    _ -> {:error, :token_exchange_failed}
  end

  def fetch_identity(access_token) when is_binary(access_token) do
    config = config!()

    request(config)
    |> Req.get(
      url: config[:profile_url],
      headers: [{"authorization", "Bearer " <> access_token}]
    )
    |> case do
      {:ok, %{status: 200, body: %{"id" => id}}} -> Snowflake.cast(id)
      _ -> :error
    end
    |> case do
      {:ok, id} -> {:ok, id}
      _ -> {:error, :profile_failed}
    end
  rescue
    _ -> {:error, :profile_failed}
  end

  defp request(config) do
    # Never forward secret-bearing forms or bearer headers through redirects.
    config[:request_options]
    |> Kernel.||([])
    |> Keyword.put(:redirect, false)
    |> Req.new()
  end

  defp config! do
    config = Application.fetch_env!(:async_worlds, :discord_oauth)

    for key <- [:client_id, :client_secret, :redirect_uri, :token_url, :profile_url] do
      value = config[key]
      if not is_binary(value) or value == "", do: raise("Discord OAuth is not configured")
    end

    config
  end
end
