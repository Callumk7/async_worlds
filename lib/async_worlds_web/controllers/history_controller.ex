defmodule AsyncWorldsWeb.HistoryController do
  use AsyncWorldsWeb, :controller
  alias AsyncWorlds.Ticks.{History, PersonalHistory}
  alias AsyncWorldsWeb.{ApiParams, ApiRequest, ApiResponse}

  def index(conn, _params) do
    scope = conn.assigns.current_scope

    with :ok <- ApiRequest.query(conn, ~w(page)),
         {:ok, page} <- ApiParams.page(conn.query_params["page"]),
         {:ok, result} <-
           History.list(scope.campaign.discord_guild_id, scope.discord_user_id, page) do
      ApiResponse.success(conn, Enum.map(result.items, &tick/1),
        meta: ApiParams.page_meta(page, 20, result.more?)
      )
    else
      {:error, reason} -> ApiResponse.domain_error(conn, reason)
    end
  end

  def show(conn, _params) do
    scope = conn.assigns.current_scope

    with :ok <- ApiRequest.query(conn, ~w(messages_page results_page clocks_page)),
         {:ok, id} <- ApiRequest.resource_id(conn),
         {:ok, pages} <- pages(conn.query_params),
         {:ok, detail} <-
           History.fetch(scope.campaign.discord_guild_id, scope.discord_user_id, id, pages) do
      sections = Map.take(detail.sections, ~w(messages results clocks))

      data = %{
        tick:
          tick(%{
            id: detail.tick.id,
            number: detail.tick.number,
            published_at: detail.tick.published_at
          }),
        draft_id: detail.publication.draft_id,
        revision: detail.revision,
        input_revision: detail.input_revision,
        world_news: detail.world_news,
        sections:
          Map.new(sections, fn {name, section} ->
            {name,
             %{
               items: Enum.map(section.items, &project(name, &1)),
               meta: ApiParams.page_meta(section.page, 20, section.more?)
             }}
          end)
      }

      ApiResponse.success(conn, data)
    else
      {:error, reason} -> ApiResponse.domain_error(conn, reason)
    end
  end

  def result(conn, _params), do: personal(conn, &PersonalHistory.dm_result/2)
  def submission(conn, _params), do: personal(conn, &PersonalHistory.dm_submission/2)

  defp personal(conn, fun) do
    with :ok <- ApiRequest.query(conn, []),
         {:ok, id} <- ApiRequest.resource_id(conn),
         {:ok, data} <- fun.(conn.assigns.current_scope, id) do
      data =
        if data do
          data
          |> Map.update!(:tick_id, &ApiResponse.id/1)
          |> Map.update!(:character_id, &ApiResponse.id/1)
          |> then(fn data ->
            if Map.has_key?(data, :published_at),
              do: Map.update!(data, :published_at, &ApiResponse.timestamp/1),
              else: data
          end)
        end

      ApiResponse.success(conn, data)
    else
      {:error, reason} -> ApiResponse.domain_error(conn, reason)
    end
  end

  defp pages(params) do
    Enum.reduce_while(params, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case ApiParams.page(value) do
        {:ok, page} -> {:cont, {:ok, Map.put(acc, String.replace_suffix(key, "_page", ""), page)}}
        error -> {:halt, error}
      end
    end)
  end

  defp tick(t),
    do: %{
      id: ApiResponse.id(t.id),
      number: t.number,
      published_at: ApiResponse.timestamp(t.published_at)
    }

  defp project("messages", m),
    do: %{
      audience: m.audience,
      character_id: ApiResponse.id(m.character_id),
      chunk: m.chunk,
      content: m.content
    }

  defp project("results", r),
    do: %{
      character_id: ApiResponse.id(r["character_id"]),
      character: r["historical_character"],
      outcome: r["outcome"],
      critical: r["critical"],
      text: r["text"]
    }

  defp project("clocks", c),
    do:
      Map.take(c, ~w(name visibility segments filled paused completed))
      |> Map.put("id", ApiResponse.id(c["id"]))
end
