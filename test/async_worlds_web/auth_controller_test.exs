defmodule AsyncWorldsWeb.AuthControllerTest do
  use AsyncWorldsWeb.ConnCase

  alias AsyncWorlds.{Campaigns, Repo, WebAuth}
  alias AsyncWorlds.WebAuth.{OAuthState, Session}

  setup do
    {:ok, campaign} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "10001",
        dm_user_id: "20002",
        public_channel_id: "30003"
      })

    %{campaign: campaign}
  end

  test "successful callback uses Req for token and profile and creates an opaque session", %{
    conn: conn
  } do
    stub_discord("20002")
    {conn, state} = begin_login(conn)

    conn = get(conn, ~p"/auth/discord/callback?code=one-time-code&state=#{state}")

    assert redirected_to(conn) == ~p"/dashboard"
    assert is_binary(get_session(conn, :web_session_token))
    assert get_session(conn, :oauth_state) == nil
    assert Repo.aggregate(Session, :count) == 1
    assert Repo.aggregate(OAuthState, :count) == 0
    refute get_resp_header(conn, "set-cookie") |> List.first() =~ "one-time-code"
  end

  test "state mismatch fails closed before calling Discord and does not consume another state", %{
    conn: conn
  } do
    Req.Test.stub(AsyncWorlds.Discord.OAuth, fn _conn -> flunk("Discord must not be called") end)
    {conn, _state} = begin_login(conn)

    conn = get(conn, ~p"/auth/discord/callback?code=secret-code&state=wrong-state")

    assert redirected_to(conn) == ~p"/login"
    assert get_session(conn, :web_session_token) == nil
    assert Repo.aggregate(OAuthState, :count) == 1
    assert Repo.aggregate(Session, :count) == 0
  end

  test "an expired state is rejected and consumed state cannot be replayed", %{conn: conn} do
    Req.Test.stub(AsyncWorlds.Discord.OAuth, fn _conn -> flunk("Discord must not be called") end)
    {conn, state} = begin_login(conn)
    Repo.update_all(OAuthState, set: [expires_at: ~U[2000-01-01 00:00:00Z]])

    conn = get(conn, ~p"/auth/discord/callback?code=secret-code&state=#{state}")
    assert redirected_to(conn) == ~p"/login"
    assert {:error, :invalid_state} = WebAuth.consume_state(state, state)
  end

  test "token endpoint failure is generic and leaves no authenticated session", %{conn: conn} do
    Req.Test.stub(AsyncWorlds.Discord.OAuth, fn conn ->
      Plug.Conn.send_resp(conn, 503, "sensitive upstream body")
    end)

    {conn, state} = begin_login(conn)

    conn = get(conn, ~p"/auth/discord/callback?code=secret-code&state=#{state}")

    assert redirected_to(conn) == ~p"/login"
    assert get_session(conn, :web_session_token) == nil
    assert Repo.aggregate(Session, :count) == 0
    assert Repo.aggregate(OAuthState, :count) == 0
  end

  test "Discord denial consumes valid state without contacting token endpoint", %{conn: conn} do
    Req.Test.stub(AsyncWorlds.Discord.OAuth, fn _conn -> flunk("Discord must not be called") end)
    {conn, state} = begin_login(conn)

    conn = get(conn, ~p"/auth/discord/callback?error=access_denied&state=#{state}")

    assert redirected_to(conn) == ~p"/login"
    assert Repo.aggregate(OAuthState, :count) == 0
  end

  test "a Discord user who is not the configured DM is denied", %{conn: conn} do
    stub_discord("99999")
    {conn, state} = begin_login(conn)

    conn = get(conn, ~p"/auth/discord/callback?code=secret-code&state=#{state}")

    assert redirected_to(conn) == ~p"/login"
    assert Repo.aggregate(Session, :count) == 0
  end

  test "expired sessions fail HTTP authorization", %{conn: conn} do
    stub_discord("20002")
    {conn, state} = begin_login(conn)
    conn = get(conn, ~p"/auth/discord/callback?code=secret-code&state=#{state}")
    Repo.update_all(Session, set: [expires_at: ~U[2000-01-01 00:00:00Z]])

    conn = get(recycle(conn), ~p"/dashboard")

    assert redirected_to(conn) == ~p"/login"
  end

  test "logout revokes the server-side session and replayed cookie is rejected", %{conn: conn} do
    stub_discord("20002")
    {conn, state} = begin_login(conn)
    conn = get(conn, ~p"/auth/discord/callback?code=secret-code&state=#{state}")
    replay_conn = recycle(conn)
    token = get_session(conn, :web_session_token)

    logged_out = delete(conn, ~p"/auth/logout")

    assert redirected_to(logged_out) == ~p"/login"
    assert {:error, :unauthorized} = WebAuth.authorize_session(token)
    assert redirected_to(get(replay_conn, ~p"/dashboard")) == ~p"/login"
  end

  test "profile exchange failure reveals no upstream credentials", %{conn: conn} do
    Req.Test.stub(AsyncWorlds.Discord.OAuth, fn conn ->
      case conn.request_path do
        "/oauth2/token" -> Req.Test.json(conn, %{"access_token" => "private-access-token"})
        "/users/@me" -> Plug.Conn.send_resp(conn, 401, "private-upstream-body")
      end
    end)

    {conn, state} = begin_login(conn)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        failed = get(conn, ~p"/auth/discord/callback?code=private-code&state=#{state}")
        assert redirected_to(failed) == ~p"/login"
        refute get_session(failed, :web_session_token)
        refute Phoenix.Flash.get(failed.assigns.flash, :error) =~ "private"
      end)

    refute log =~ "private-access-token"
    refute log =~ "private-upstream-body"
    refute log =~ "private-code"
    assert Repo.aggregate(Session, :count) == 0
    assert Repo.aggregate(OAuthState, :count) == 0
  end

  test "token exchange refuses redirects rather than forwarding a secret-bearing form", %{
    conn: conn
  } do
    Req.Test.stub(AsyncWorlds.Discord.OAuth, fn conn ->
      case conn.request_path do
        "/oauth2/token" ->
          conn
          |> Plug.Conn.put_resp_header("location", "/forwarded-secret")
          |> Plug.Conn.put_status(307)
          |> Req.Test.json(%{})

        "/forwarded-secret" ->
          send(self(), :secret_form_forwarded)
          Req.Test.json(conn, %{"access_token" => "redirected-token"})

        "/users/@me" ->
          Req.Test.json(conn, %{"id" => "20002"})
      end
    end)

    {conn, state} = begin_login(conn)
    conn = get(conn, ~p"/auth/discord/callback?code=secret-code&state=#{state}")
    refute_received :secret_form_forwarded
    assert redirected_to(conn) == ~p"/login"
    assert Repo.aggregate(Session, :count) == 0
  end

  test "successful state cannot be replayed even with the initiating cookie", %{conn: conn} do
    stub_discord("20002")
    {conn, state} = begin_login(conn)
    replay_conn = conn

    assert redirected_to(get(conn, ~p"/auth/discord/callback?code=secret-code&state=#{state}")) ==
             ~p"/dashboard"

    Req.Test.stub(AsyncWorlds.Discord.OAuth, fn _ ->
      flunk("replayed state must not call Discord")
    end)

    assert redirected_to(
             get(replay_conn, ~p"/auth/discord/callback?code=secret-code&state=#{state}")
           ) == ~p"/login"

    assert Repo.aggregate(Session, :count) == 1
  end

  defp begin_login(conn) do
    conn = get(conn, ~p"/auth/discord")
    location = redirected_to(conn)

    state =
      location |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("state")

    {recycle(conn), state}
  end

  defp stub_discord(user_id) do
    Req.Test.stub(AsyncWorlds.Discord.OAuth, fn conn ->
      case conn.request_path do
        "/oauth2/token" ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          assert URI.decode_query(body)["code"] in ["one-time-code", "secret-code"]
          Req.Test.json(conn, %{"access_token" => "upstream-access-token"})

        "/users/@me" ->
          assert Plug.Conn.get_req_header(conn, "authorization") == [
                   "Bearer upstream-access-token"
                 ]

          Req.Test.json(conn, %{"id" => user_id, "username" => "not-persisted"})
      end
    end)
  end
end
