defmodule AsyncWorldsWeb.PageControllerTest do
  use AsyncWorldsWeb.ConnCase

  test "GET /", %{conn: conn} do
    document = conn |> get(~p"/") |> html_response(200) |> LazyHTML.from_document()

    assert [{"section", attributes, _children}] =
             document |> LazyHTML.query_by_id("login-page") |> LazyHTML.to_tree()

    assert {"id", "login-page"} in attributes
  end
end
