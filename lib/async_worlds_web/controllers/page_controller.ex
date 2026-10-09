defmodule AsyncWorldsWeb.PageController do
  use AsyncWorldsWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
