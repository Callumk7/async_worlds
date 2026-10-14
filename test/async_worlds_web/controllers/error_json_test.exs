defmodule AsyncWorldsWeb.ErrorJSONTest do
  use AsyncWorldsWeb.ConnCase, async: true

  test "renders 404" do
    assert AsyncWorldsWeb.ErrorJSON.render("404.json", %{}) == %{error: %{code: "not_found"}}
  end

  test "invalid JSON and exceptions share safe API envelopes" do
    error = %Plug.Parsers.ParseError{exception: RuntimeError.exception("PRIVATE BODY")}

    assert AsyncWorldsWeb.ErrorJSON.render("400.json", %{reason: error}) == %{
             error: %{code: "invalid_json"}
           }

    assert AsyncWorldsWeb.ErrorJSON.render("500.json", %{reason: RuntimeError.exception("SECRET")}) ==
             %{error: %{code: "internal_error"}}
  end

  test "renders 500" do
    assert AsyncWorldsWeb.ErrorJSON.render("500.json", %{}) ==
             %{error: %{code: "internal_error"}}
  end
end
