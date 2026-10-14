defmodule AsyncWorldsWeb.QuestAuthoringController do
  use AsyncWorldsWeb, :controller

  alias AsyncWorlds.Quests
  alias AsyncWorldsWeb.{ApiParams, ApiResponse}

  @fields [:name, :content_id, :definition]
  @editable Enum.map(@fields, &Atom.to_string/1)

  def index(conn, _params), do: collection(conn, :library)
  def revisions(conn, _params), do: collection(conn, :revisions)
  def working_copies(conn, _params), do: collection(conn, :drafts)

  defp collection(conn, kind) do
    scope = conn.assigns.current_scope

    with :ok <- query(conn),
         {:ok, library} <- Quests.library(scope.campaign, scope.discord_user_id) do
      revisions = Enum.map(library.revisions, &revision_summary/1)
      drafts = Enum.map(library.drafts, &work_summary/1)

      data =
        case kind do
          :library -> %{revisions: revisions, working_copies: drafts}
          :revisions -> revisions
          :drafts -> drafts
        end

      ApiResponse.success(conn, data)
    else
      {:error, reason} -> ApiResponse.domain_error(conn, reason, @fields)
    end
  end

  def revision(conn, _params) do
    scope = conn.assigns.current_scope

    with :ok <- query(conn),
         {:ok, id} <- resource_id(conn.path_params["id"]),
         {:ok, revision} <- Quests.get_revision(scope.campaign, scope.discord_user_id, id) do
      ApiResponse.success(conn, project_revision(revision))
    else
      {:error, reason} -> ApiResponse.domain_error(conn, reason, @fields)
    end
  end

  def show(conn, _params) do
    scope = conn.assigns.current_scope

    with :ok <- query(conn),
         {:ok, id} <- resource_id(conn.path_params["id"]),
         {:ok, work} <- Quests.get_working_copy(scope.campaign, scope.discord_user_id, id) do
      ApiResponse.success(conn, project_work(work))
    else
      {:error, reason} -> ApiResponse.domain_error(conn, reason, @fields)
    end
  end

  def create(conn, _params) do
    scope = conn.assigns.current_scope

    with {:ok, params} <- body(conn, ["revision_id"]),
         {:ok, revision_id} <- optional_revision(params),
         {:ok, work} <-
           Quests.create_working_copy(scope.campaign, scope.discord_user_id, revision_id) do
      ApiResponse.success(conn, project_work(work), status: 201)
    else
      {:error, reason} -> ApiResponse.domain_error(conn, reason, @fields)
    end
  end

  def save(conn, _params), do: mutate(conn, :save)
  def release(conn, _params), do: mutate(conn, :release)
  def recover(conn, _params), do: mutate(conn, :recover)

  defp mutate(conn, operation) do
    scope = conn.assigns.current_scope
    allowed = if operation == :recover, do: @editable, else: ["version" | @editable]

    with {:ok, params} <- body(conn, allowed),
         {:ok, id} <- resource_id(conn.path_params["id"]),
         {:ok, version} <- mutation_version(operation, params),
         {:ok, attrs} <- attributes(params),
         {:ok, result} <- apply_mutation(scope, operation, id, version, attrs) do
      data =
        case operation do
          :release ->
            %{
              working_copy: project_work(result.draft),
              revision: project_revision(result.revision)
            }

          _ ->
            project_work(result)
        end

      ApiResponse.success(conn, data, status: if(operation == :recover, do: 201, else: 200))
    else
      {:error, reason} -> ApiResponse.domain_error(conn, reason, @fields)
    end
  end

  defp apply_mutation(scope, :save, id, version, attrs),
    do: Quests.save_working_copy(scope.campaign, scope.discord_user_id, id, version, attrs)

  defp apply_mutation(scope, :release, id, version, attrs),
    do: Quests.release_working_copy(scope.campaign, scope.discord_user_id, id, version, attrs)

  defp apply_mutation(scope, :recover, id, _version, attrs),
    do: Quests.recover_working_copy(scope.campaign, scope.discord_user_id, id, attrs)

  # Recovery creates a separate quest identity; it never overwrites the original.
  defp mutation_version(:recover, _params), do: {:ok, nil}
  defp mutation_version(_, params), do: ApiParams.version(params["version"])

  defp attributes(%{"name" => name, "content_id" => content_id, "definition" => definition})
       when is_binary(name) and is_binary(content_id) and is_map(definition),
       do: {:ok, %{name: name, content_id: content_id, definition: definition}}

  defp attributes(_), do: {:error, :invalid_parameters}

  defp optional_revision(params) do
    if Map.has_key?(params, "revision_id"),
      do: resource_id(params["revision_id"]),
      else: {:ok, nil}
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

  defp revision_summary(revision) do
    %{
      id: ApiResponse.id(revision.id),
      name: revision.name,
      content_id: revision.content_id,
      number: revision.number
    }
  end

  defp project_revision(revision) do
    %{
      id: ApiResponse.id(revision.id),
      campaign_id: ApiResponse.id(revision.campaign_id),
      quest_id: ApiResponse.id(revision.quest_id),
      number: revision.number,
      definition: revision.definition
    }
  end

  defp work_summary(work) do
    %{
      id: ApiResponse.id(work.id),
      campaign_id: ApiResponse.id(work.campaign_id),
      quest_id: ApiResponse.id(work.quest_id),
      base_revision_id: ApiResponse.id(work.base_revision_id),
      name: work.name,
      content_id: work.content_id,
      version: work.version,
      inserted_at: ApiResponse.timestamp(work.inserted_at),
      updated_at: ApiResponse.timestamp(work.updated_at)
    }
  end

  # Definition is authoring content, not an internal snapshot: preserve opaque
  # fields and native clock references exactly so read/save never rewrites imports.
  defp project_work(work), do: Map.put(work_summary(work), :definition, work.definition)
end
