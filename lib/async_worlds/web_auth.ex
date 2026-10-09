defmodule AsyncWorlds.WebAuth do
  @moduledoc "Server-side OAuth state and revocable DM web sessions."

  import Ecto.Query

  alias AsyncWorlds.Campaigns
  alias AsyncWorlds.Discord.OAuth
  alias AsyncWorlds.Repo
  alias AsyncWorlds.WebAuth.{OAuthState, Session}

  @state_bytes 32
  @session_bytes 32

  def begin_oauth do
    state = random_token(@state_bytes)
    now = now()
    expires_at = DateTime.add(now, config(:state_ttl_seconds, 600), :second)

    Repo.delete_all(from s in OAuthState, where: s.expires_at <= ^now)

    case Repo.insert(%OAuthState{token_hash: hash(state), expires_at: expires_at}) do
      {:ok, _record} -> {:ok, state, OAuth.authorization_url(state)}
      {:error, _changeset} -> {:error, :oauth_unavailable}
    end
  rescue
    _ -> {:error, :oauth_unavailable}
  end

  @doc "Consumes a state once, only for the browser session that initiated it."
  def consume_state(state, expected_state)
      when is_binary(state) and is_binary(expected_state) do
    if secure_compare(state, expected_state) do
      {count, _} =
        from(s in OAuthState,
          where: s.token_hash == ^hash(state) and s.expires_at > ^now()
        )
        |> Repo.delete_all()

      if count == 1, do: :ok, else: {:error, :invalid_state}
    else
      {:error, :invalid_state}
    end
  end

  def consume_state(_, _), do: {:error, :invalid_state}

  def complete_oauth(state, expected_state, code) when is_binary(code) do
    with :ok <- consume_state(state, expected_state),
         {:ok, access_token} <- OAuth.exchange_code(code),
         {:ok, user_id} <- OAuth.fetch_identity(access_token),
         {:ok, campaign} <- Campaigns.authorize_dm_user(user_id),
         {:ok, token, session} <- create_session(user_id, campaign.discord_guild_id) do
      {:ok, token, scope(session, campaign)}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :authentication_failed}
    end
  end

  def complete_oauth(_, _, _), do: {:error, :authentication_failed}

  def authorize_session(token) when is_binary(token) do
    current_time = now()

    query =
      from s in Session,
        where:
          s.token_hash == ^hash(token) and is_nil(s.revoked_at) and s.expires_at > ^current_time

    with %Session{} = session <- Repo.one(query),
         {:ok, campaign} <-
           Campaigns.authorize_dm(session.discord_guild_id, session.discord_user_id) do
      {:ok, scope(session, campaign)}
    else
      _ -> {:error, :unauthorized}
    end
  end

  def authorize_session(_), do: {:error, :unauthorized}

  def revoke_session(token) when is_binary(token) do
    current_time = now()

    case Repo.one(from s in Session, where: s.token_hash == ^hash(token)) do
      nil ->
        :ok

      session ->
        from(s in Session, where: s.id == ^session.id and is_nil(s.revoked_at))
        |> Repo.update_all(set: [revoked_at: current_time, updated_at: current_time])

        Phoenix.PubSub.broadcast(AsyncWorlds.PubSub, session_topic(session.id), :session_revoked)
        :ok
    end
  end

  def revoke_session(_), do: :ok

  def session_topic(id), do: "web_session:#{id}"

  defp create_session(user_id, guild_id) do
    token = random_token(@session_bytes)
    current_time = now()

    attrs = %{
      token_hash: hash(token),
      discord_user_id: user_id,
      discord_guild_id: guild_id,
      expires_at: DateTime.add(current_time, config(:session_ttl_seconds, 28_800), :second)
    }

    case Repo.insert(struct(Session, attrs)) do
      {:ok, session} -> {:ok, token, session}
      {:error, _changeset} -> {:error, :session_failed}
    end
  end

  defp scope(session, campaign) do
    %{
      session_id: session.id,
      discord_user_id: session.discord_user_id,
      campaign: campaign,
      expires_at: session.expires_at
    }
  end

  defp random_token(bytes),
    do: bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  defp hash(value), do: :crypto.hash(:sha256, value)

  defp secure_compare(left, right) when byte_size(left) == byte_size(right),
    do: Plug.Crypto.secure_compare(left, right)

  defp secure_compare(_, _), do: false
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp config(key, default) do
    :async_worlds
    |> Application.get_env(:web_auth, [])
    |> Keyword.get(key, default)
  end
end
