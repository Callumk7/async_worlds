defmodule AsyncWorldsWeb.QuestInterventionController do
  use AsyncWorldsWeb, :controller

  alias AsyncWorlds.Quests
  alias AsyncWorldsWeb.{ApiParams, ApiResponse}

  @progression_fields ~w(id campaign_id character_id revision_id node_id position_version status)

  def management(conn, _params) do
    scope = conn.assigns.current_scope

    with :ok <- query(conn),
         {:ok, character_id} <- selected_id(conn),
         {:ok, state} <-
           Quests.management_state(scope.campaign, scope.discord_user_id, character_id) do
      ApiResponse.success(conn, %{
        characters: Enum.map(state.characters, &character_row/1),
        revisions: Enum.map(state.revisions, &revision_summary/1),
        selected: selected(state.selected),
        interventions: Enum.map(state.audits, &intervention/1),
        locked: state.locked
      })
    else
      {:error, reason} -> ApiResponse.domain_error(conn, reason)
    end
  end

  def unlocked(conn, _params) do
    scope = conn.assigns.current_scope

    with :ok <- query(conn),
         {:ok, id} <- resource_id(conn.path_params["id"]),
         {:ok, quests} <- Quests.list_unlocked(scope.campaign, scope.discord_user_id, id) do
      ApiResponse.success(conn, Enum.map(quests, &quest/1))
    else
      {:error, reason} -> ApiResponse.domain_error(conn, reason)
    end
  end

  def interventions(conn, _params) do
    scope = conn.assigns.current_scope

    with :ok <- query(conn),
         {:ok, id} <- resource_id(conn.path_params["id"]),
         {:ok, audits} <- Quests.list_interventions(scope.campaign, scope.discord_user_id, id) do
      ApiResponse.success(conn, Enum.map(audits, &intervention/1))
    else
      {:error, reason} -> ApiResponse.domain_error(conn, reason)
    end
  end

  def assign_quest(conn, _params), do: mutate(conn, :assign)
  def replace(conn, _params), do: mutate(conn, :replace)
  def move(conn, _params), do: mutate(conn, :move)
  def end_quest(conn, _params), do: mutate(conn, :end)

  defp mutate(conn, operation) do
    scope = conn.assigns.current_scope

    allowed =
      case operation do
        op when op in [:assign, :replace] -> ["revision_id"]
        :move -> ["node_id"]
        :end -> []
      end

    with {:ok, params} <- body(conn, ["reason", "expected_progression" | allowed]),
         {:ok, expected} <- expected_input(params),
         {:ok, id} <- resource_id(conn.path_params["id"]),
         {:ok, state} <- Quests.management_state(scope.campaign, scope.discord_user_id, id),
         :ok <- compare_expected(state.selected.progression, expected),
         {:ok, result} <- apply_mutation(scope, operation, state.selected, params) do
      ApiResponse.success(conn, progression(result))
    else
      {:error, reason} -> ApiResponse.domain_error(conn, reason)
    end
  end

  defp apply_mutation(scope, operation, selected, params) do
    # Client maps are preconditions only. The locked domain receives the exact
    # server-loaded record (or explicit absence), never a client-built schema.
    opts = [reason: params["reason"], expected_progression: selected.progression]

    case operation do
      op when op in [:assign, :replace] ->
        with {:ok, revision_id} <- resource_id(params["revision_id"]) do
          if op == :assign,
            do:
              Quests.assign(scope.campaign, scope.discord_user_id, selected.id, revision_id, opts),
            else:
              Quests.swap(scope.campaign, scope.discord_user_id, selected.id, revision_id, opts)
        end

      :move ->
        cond do
          is_nil(selected.progression) ->
            {:error, :no_quest}

          not is_binary(params["node_id"]) ->
            {:error, :invalid_node}

          true ->
            Quests.move(
              scope.campaign,
              scope.discord_user_id,
              selected.progression.id,
              params["node_id"],
              opts
            )
        end

      :end ->
        if selected.progression,
          do:
            Quests.end_quest(scope.campaign, scope.discord_user_id, selected.progression.id, opts),
          else: {:error, :no_quest}
    end
  end

  defp expected_input(params) do
    case Map.fetch(params, "expected_progression") do
      :error -> {:error, :precondition_required}
      {:ok, nil} -> {:ok, nil}
      {:ok, expected} when is_map(expected) -> parse_expected(expected)
      _ -> {:error, :invalid_parameters}
    end
  end

  defp parse_expected(expected) do
    with {:ok, version} <- ApiParams.version(expected["position_version"]),
         true <- Enum.sort(Map.keys(expected)) == Enum.sort(@progression_fields),
         {:ok, id} <- ApiParams.id(expected["id"]),
         {:ok, campaign_id} <- ApiParams.id(expected["campaign_id"]),
         {:ok, character_id} <- ApiParams.id(expected["character_id"]),
         {:ok, revision_id} <- ApiParams.id(expected["revision_id"]),
         true <- is_binary(expected["node_id"]) and byte_size(expected["node_id"]) in 1..100,
         true <- expected["status"] in ["active", "completed", "ended"] do
      {:ok,
       %{
         id: ApiResponse.id(id),
         campaign_id: ApiResponse.id(campaign_id),
         character_id: ApiResponse.id(character_id),
         revision_id: ApiResponse.id(revision_id),
         node_id: expected["node_id"],
         position_version: version,
         status: expected["status"]
       }}
    else
      {:error, :precondition_required} -> {:error, :precondition_required}
      _ -> {:error, :invalid_parameters}
    end
  end

  defp compare_expected(current, expected) do
    if progression(current) == expected, do: :ok, else: {:error, :stale_progression}
  end

  defp selected_id(conn) do
    case Map.fetch(conn.path_params, "id") do
      {:ok, id} -> resource_id(id)
      :error -> {:ok, nil}
    end
  end

  defp resource_id(value) do
    case ApiParams.id(value) do
      {:ok, id} -> {:ok, id}
      _ -> {:error, :not_found}
    end
  end

  defp query(conn) do
    if conn.query_params == %{}, do: :ok, else: {:error, :invalid_parameters}
  end

  defp body(conn, allowed) do
    with :ok <- query(conn),
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

  defp progression(nil), do: nil

  defp progression(record) do
    %{
      id: ApiResponse.id(record.id),
      campaign_id: ApiResponse.id(record.campaign_id),
      character_id: ApiResponse.id(record.character_id),
      revision_id: ApiResponse.id(record.revision_id),
      node_id: record.node_id,
      position_version: record.position_version,
      status: Atom.to_string(record.status)
    }
  end

  defp character_row(row) do
    %{
      id: ApiResponse.id(row.id),
      name: row.name,
      discord_user_id: ApiResponse.id(row.discord_user_id),
      progression: progression(row.progression),
      quest_name: row.quest_name,
      revision_number: row.revision_number
    }
  end

  defp selected(nil), do: nil

  defp selected(row) do
    revision =
      if row.revision,
        do: %{
          id: ApiResponse.id(row.revision.id),
          campaign_id: ApiResponse.id(row.revision.campaign_id),
          quest_id: ApiResponse.id(row.revision.quest_id),
          number: row.revision.number,
          definition: row.revision.definition
        }

    Map.put(character_row(row), :revision, revision)
  end

  defp revision_summary(row),
    do: %{
      id: ApiResponse.id(row.id),
      quest_name: row.quest_name,
      content_id: row.content_id,
      number: row.number
    }

  defp quest(record),
    do: %{
      id: ApiResponse.id(record.id),
      campaign_id: ApiResponse.id(record.campaign_id),
      name: record.name,
      content_id: record.content_id
    }

  defp intervention(record),
    do: %{
      id: ApiResponse.id(record.id),
      campaign_id: ApiResponse.id(record.campaign_id),
      character_id: ApiResponse.id(record.character_id),
      tick_id: ApiResponse.id(record.tick_id),
      actor_id: record.actor_id,
      operation: record.operation,
      reason: record.reason,
      before: position(record.before),
      after: position(record.after),
      invalidated_submissions: record.invalidated_submissions,
      inserted_at: ApiResponse.timestamp(record.inserted_at)
    }

  defp position(nil), do: nil

  defp position(record),
    do: %{
      id: ApiResponse.id(record["id"]),
      character_id: ApiResponse.id(record["character_id"]),
      revision_id: ApiResponse.id(record["revision_id"]),
      node_id: record["node_id"],
      position_version: record["position_version"],
      status: record["status"]
    }
end
