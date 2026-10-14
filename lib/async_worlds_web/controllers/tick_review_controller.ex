defmodule AsyncWorldsWeb.TickReviewController do
  use AsyncWorldsWeb, :controller

  alias AsyncWorlds.DM.Ticks
  alias AsyncWorlds.Ticks.QuestReview
  alias AsyncWorldsWeb.{ApiParams, ApiResponse}

  @input_ids ~w(character_id progression_id revision_id)
  @input_fields @input_ids ++ ~w(node_id position_version choice_id)

  def show(conn, _params) do
    with :ok <- query(conn, []),
         {:ok, id} <- resource_id(conn),
         {:ok, review} <- Ticks.review(conn.assigns.current_scope, id) do
      ApiResponse.success(conn, project_review(review))
    else
      {:error, reason} -> ApiResponse.domain_error(conn, reason)
    end
  end

  def audits(conn, _params) do
    with :ok <- query(conn, []),
         {:ok, id} <- resource_id(conn),
         {:ok, edits} <- Ticks.list_review_edits(conn.assigns.current_scope, id) do
      ApiResponse.success(conn, Enum.map(edits, &project_audit/1))
    else
      {:error, reason} -> ApiResponse.domain_error(conn, reason)
    end
  end

  def preview(conn, _params) do
    with :ok <- query(conn, ["draft_id"]),
         {:ok, id} <- resource_id(conn),
         {:ok, draft_id} <- ApiParams.uuid(conn.query_params["draft_id"]),
         {:ok, outputs} <- Ticks.preview_draft(conn.assigns.current_scope, id, draft_id) do
      data =
        Map.new(~w(public dm players), fn audience ->
          {audience, Enum.map(outputs[audience] || [], &project_message/1)}
        end)

      ApiResponse.success(conn, %{draft_id: draft_id, outputs: data})
    else
      {:error, reason} -> ApiResponse.domain_error(conn, reason)
    end
  end

  def edit(conn, _params) do
    with {:ok, params} <- body(conn, ~w(draft_id reason operation)),
         {:ok, id} <- resource_id(conn),
         {:ok, draft_id} <- ApiParams.uuid(params["draft_id"]),
         {:ok, operation} <- operation(params["operation"]),
         {:ok, %{draft: draft, edit: edit}} <-
           Ticks.edit_draft(conn.assigns.current_scope, id, draft_id, operation, params["reason"]) do
      ApiResponse.success(conn, %{draft: project_draft(draft), audit: project_audit(edit)})
    else
      {:error, reason} -> ApiResponse.domain_error(conn, reason)
    end
  end

  def publish(conn, _params) do
    with {:ok, params} <- body(conn, ~w(draft_id confirm)),
         {:ok, id} <- resource_id(conn),
         {:ok, draft_id} <- ApiParams.uuid(params["draft_id"]),
         :ok <- confirmation(params["confirm"]),
         {:ok, tick} <- Ticks.publish_tick(conn.assigns.current_scope, id, draft_id) do
      ApiResponse.success(conn, %{
        tick_id: ApiResponse.id(tick.id),
        number: tick.number,
        status: Atom.to_string(tick.status),
        published_at: ApiResponse.timestamp(tick.published_at)
      })
    else
      {:error, reason} -> ApiResponse.domain_error(conn, reason)
    end
  end

  defp confirmation(true), do: :ok
  defp confirmation(value) when value in [nil, false], do: {:error, :confirmation_required}
  defp confirmation(_), do: {:error, :invalid_parameters}

  defp operation(%{"type" => "clock_delta"} = op) when map_size(op) == 3 do
    with true <- Enum.sort(Map.keys(op)) == ~w(clock_id delta type),
         {:ok, id} <- ApiParams.id(op["clock_id"]),
         true <- is_nil(op["delta"]) or is_integer(op["delta"]) do
      {:ok, Map.put(op, "clock_id", id)}
    else
      _ -> {:error, :invalid_edit}
    end
  end

  defp operation(%{"type" => "world_news", "text" => _} = op) when map_size(op) == 2,
    do: {:ok, op}

  defp operation(%{"type" => "reroll", "identity" => identity, "old_value" => value} = op)
       when map_size(op) == 3 and is_binary(identity) and is_integer(value) and value in 1..6,
       do: {:ok, op}

  defp operation(
         %{"type" => type, "input_revision" => revision, "input" => input, "value" => _} = op
       )
       when type in ["outcome", "player_narration"] and map_size(op) == 4 do
    with {:ok, revision} <- ApiParams.uuid(revision),
         {:ok, input} <- parse_input(input) do
      {:ok, op |> Map.put("input_revision", revision) |> Map.put("input", input)}
    end
  end

  defp operation(_), do: {:error, :invalid_edit}

  defp parse_input(input) when is_map(input) do
    with true <- Enum.sort(Map.keys(input)) == Enum.sort(@input_fields),
         true <- is_binary(input["node_id"]) and is_binary(input["choice_id"]),
         {:ok, version} <- ApiParams.version(input["position_version"]) do
      Enum.reduce_while(@input_ids, {:ok, Map.put(input, "position_version", version)}, fn field,
                                                                                           {:ok,
                                                                                            acc} ->
        case ApiParams.id(input[field]) do
          {:ok, id} -> {:cont, {:ok, Map.put(acc, field, id)}}
          _ -> {:halt, {:error, :invalid_edit}}
        end
      end)
    else
      _ -> {:error, :invalid_edit}
    end
  end

  defp parse_input(_), do: {:error, :invalid_edit}

  defp resource_id(conn) do
    case ApiParams.id(conn.path_params["id"]) do
      {:ok, id} -> {:ok, id}
      _ -> {:error, :not_found}
    end
  end

  defp query(conn, allowed) do
    if Map.keys(conn.query_params) -- allowed == [], do: :ok, else: {:error, :invalid_parameters}
  end

  defp body(conn, allowed) do
    with :ok <- query(conn, []),
         [content_type] <- get_req_header(conn, "content-type"),
         "application/json" <- content_type |> String.split(";") |> hd() |> String.trim(),
         params when is_map(params) <- conn.body_params,
         true <- Map.keys(params) -- allowed == [] do
      {:ok, params}
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :invalid_parameters}
      _ -> {:error, :unsupported_media_type}
    end
  end

  defp project_draft(draft) do
    %{
      id: draft.id,
      tick_id: ApiResponse.id(draft.tick_id),
      input_revision: draft.input_revision,
      revision: draft.revision,
      inserted_at: ApiResponse.timestamp(draft.inserted_at)
    }
  end

  defp project_review(%{draft: draft, snapshot: snapshot}) do
    payload = draft.payload
    review = payload["review"] || %{}

    Map.merge(project_draft(draft), %{
      world_news: payload["world_news"],
      world_news_override: review["world_news"],
      clocks:
        Enum.map(payload["clocks"], fn clock ->
          frozen = Enum.find(snapshot.data["clocks"], &(&1["id"] == clock["id"]))

          %{
            id: ApiResponse.id(clock["id"]),
            name: clock["name"],
            visibility: clock["visibility"],
            segments: clock["segments"],
            filled: clock["filled"],
            paused: clock["paused"],
            completed: clock["completed"],
            frozen_filled: frozen["filled"],
            frozen_completed: frozen["completed"],
            delta_override: get_in(review, ["clock_deltas", to_string(clock["id"])])
          }
        end),
      quests:
        Enum.map(payload["private_results"] || [], fn result ->
          input = result["input"]
          key = QuestReview.key(snapshot, input)
          character = Enum.find(payload["characters"], &(&1["id"] == result["character_id"]))

          %{
            character_id: ApiResponse.id(result["character_id"]),
            name: character["name"],
            input: project_input(input),
            outcome: result["outcome"],
            critical: result["critical"],
            text: result["text"],
            before: project_position(result["before"]),
            after: project_position(result["after"]),
            outcome_override: get_in(review, ["outcomes", key]),
            narration_override: get_in(review, ["narration", key]),
            next: project_next(payload, result["character_id"]),
            dice:
              payload["rolls"]
              |> Enum.filter(&(&1["input"] == input))
              |> Enum.map(fn die ->
                %{identity: die["identity"], die_index: die["die_index"], value: die["value"]}
              end)
          }
        end)
    })
  end

  defp project_input(input) do
    input
    |> Map.take(@input_fields)
    |> Map.new(fn {field, value} ->
      {field, if(field in @input_ids, do: ApiResponse.id(value), else: value)}
    end)
  end

  defp project_next(payload, character_id) do
    next = Enum.find(payload["next_nodes"], &(&1["character_id"] == character_id))["projection"]

    %{
      text: next["text"],
      completed: next["completed"],
      choices: Enum.map(next["choices"], &Map.take(&1, ~w(id label enabled hint)))
    }
  end

  defp project_position(position), do: Map.take(position, ~w(node_id status position_version))

  defp project_audit(edit) do
    %{
      id: ApiResponse.id(edit.id),
      actor_id: ApiResponse.id(edit.actor_id),
      previous_draft_id: edit.previous_draft_id,
      draft_id: edit.draft_id,
      reason: edit.reason,
      inserted_at: ApiResponse.timestamp(edit.inserted_at),
      operation: project_operation(edit.operation)
    }
  end

  defp project_operation(%{"type" => "clock_delta"} = op),
    do: %{type: "clock_delta", clock_id: ApiResponse.id(op["clock_id"]), delta: op["delta"]}

  defp project_operation(%{"type" => "world_news"} = op), do: Map.take(op, ~w(type text))

  defp project_operation(%{"type" => "reroll"} = op),
    do: Map.take(op, ~w(type identity old_value new_value))

  defp project_operation(op),
    do: %{
      type: op["type"],
      input_revision: op["input_revision"],
      input: project_input(op["input"]),
      value: op["value"]
    }

  defp project_message(message) do
    %{
      kind: message["kind"],
      recipient_id: ApiResponse.id(message["recipient_id"]),
      content: message["content"]
    }
  end
end
