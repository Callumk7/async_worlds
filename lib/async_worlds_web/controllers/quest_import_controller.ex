defmodule AsyncWorldsWeb.QuestImportController do
  use AsyncWorldsWeb, :controller
  alias AsyncWorlds.Quests

  def create(conn, _params) do
    with :ok <- valid_json(conn.assigns.quest_import_json),
         {:ok, bindings} <- clock_bindings(conn.query_params),
         {:ok, results} <-
           Quests.import_json(
             conn.assigns.current_scope.campaign,
             conn.assigns.current_scope.discord_user_id,
             conn.assigns.quest_import_json,
             clock_refs: bindings
           ) do
      data =
        Enum.map(results, fn %{action: action, revision: revision} ->
          %{
            action: action,
            quest_id: revision.quest_id,
            revision_id: revision.id,
            revision_number: revision.number
          }
        end)

      json(conn, %{data: data})
    else
      {:error, errors} when is_list(errors) ->
        conn |> put_status(422) |> json(%{error: %{code: "invalid_document", details: errors}})

      {:error, {:invalid_json, message}} ->
        conn
        |> put_status(400)
        |> json(%{error: %{code: "invalid_json", details: [%{path: "$", message: message}]}})

      {:error, :invalid_bindings} ->
        conn |> put_status(422) |> json(%{error: %{code: "invalid_clock_refs"}})

      {:error, _} ->
        conn |> put_status(404) |> json(%{error: %{code: "not_found"}})
    end
  end

  defp valid_json(body) do
    case Jason.decode(body, objects: :ordered_objects) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, {:invalid_json, Exception.message(error)}}
    end
  end

  defp clock_bindings(params) do
    bindings = Map.get(params, "clock_refs", %{})

    if Map.keys(params) -- ["clock_refs"] == [] and is_map(bindings) do
      Enum.reduce_while(bindings, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
        case if(is_binary(value), do: Integer.parse(value), else: :error) do
          {id, ""} when id > 0 -> {:cont, {:ok, Map.put(acc, key, id)}}
          _ -> {:halt, {:error, :invalid_bindings}}
        end
      end)
    else
      {:error, :invalid_bindings}
    end
  end
end
