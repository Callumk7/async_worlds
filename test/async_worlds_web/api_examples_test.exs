defmodule AsyncWorldsWeb.ApiExamplesTest do
  use ExUnit.Case, async: true

  test "committed operation examples contain no credentials and resolve to real API routes" do
    export = File.read!("yaak/http-operations.json") |> Jason.decode!()
    resources = export["resources"]

    environment =
      Enum.find(resources["environments"], &(&1["name"] == "HTTP operations examples"))

    token = Enum.find(environment["variables"], &(&1["name"] == "DM_API_TOKEN"))
    assert token["value"] == ""
    assert length(resources["httpRequests"]) == 30

    for request <- resources["httpRequests"] do
      path =
        request["url"]
        |> String.replace("${[ BASE_URL ]}", "")
        |> String.replace(~r/\$\{\[ [A-Z_]+ \]\}/, "1")
        |> String.split("?")
        |> hd()

      route =
        Phoenix.Router.route_info(AsyncWorldsWeb.Router, request["method"], path, "localhost")

      assert is_map(route), "Example #{request["name"]} has no matching route"
      assert route.plug != AsyncWorldsWeb.PageController
      assert request["authentication"] == %{}

      if request["bodyType"] == "application/json" do
        assert is_map(Jason.decode!(request["body"]["text"]))

        assert Enum.any?(
                 request["headers"],
                 &(&1["name"] == "Content-Type" and &1["value"] == "application/json")
               )
      end
    end

    for folder <- resources["folders"] do
      assert Enum.any?(
               folder["headers"],
               &(&1["name"] == "Authorization" and &1["value"] == "Bearer ${[ DM_API_TOKEN ]}")
             )
    end
  end
end
