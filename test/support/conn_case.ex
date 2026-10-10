defmodule AsyncWorldsWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use AsyncWorldsWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint AsyncWorldsWeb.Endpoint

      use AsyncWorldsWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import AsyncWorldsWeb.ConnCase
    end
  end

  @endpoint AsyncWorldsWeb.Endpoint
  require Phoenix.ConnTest

  def log_in_dm(conn, campaign) do
    Req.Test.stub(AsyncWorlds.Discord.OAuth, fn request ->
      case request.request_path do
        "/oauth2/token" -> Req.Test.json(request, %{"access_token" => "test-access-token"})
        "/users/@me" -> Req.Test.json(request, %{"id" => campaign.dm_user_id})
      end
    end)

    conn = Phoenix.ConnTest.get(conn, "/auth/discord")

    state =
      conn
      |> Phoenix.ConnTest.redirected_to()
      |> URI.parse()
      |> Map.fetch!(:query)
      |> URI.decode_query()
      |> Map.fetch!("state")

    conn =
      Phoenix.ConnTest.get(
        Phoenix.ConnTest.recycle(conn),
        "/auth/discord/callback?code=test-code&state=#{state}"
      )

    Phoenix.ConnTest.recycle(conn)
  end

  setup tags do
    AsyncWorlds.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
