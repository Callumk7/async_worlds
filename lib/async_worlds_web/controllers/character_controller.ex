defmodule AsyncWorldsWeb.CharacterController do
  use AsyncWorldsWeb, :controller

  alias AsyncWorlds.Characters
  alias AsyncWorldsWeb.{ApiParams, ApiResponse}

  @fields [:name, :discord_user_id, :flags]
  @editable Enum.map(@fields, &Atom.to_string/1)

  def index(conn, _params) do
    scope = conn.assigns.current_scope

    with :ok <- query(conn),
         {:ok, characters} <- Characters.list_characters(scope.campaign, scope.discord_user_id) do
      ApiResponse.success(conn, Enum.map(characters, &project/1))
    else
      {:error, reason} -> ApiResponse.domain_error(conn, reason, @fields)
    end
  end

  def show(conn, _params) do
    scope = conn.assigns.current_scope

    with :ok <- query(conn),
         {:ok, character} <-
           Characters.get_character(scope.campaign, scope.discord_user_id, conn.path_params["id"]) do
      ApiResponse.success(conn, project(character))
    else
      {:error, reason} -> ApiResponse.domain_error(conn, reason, @fields)
    end
  end

  def create(conn, _params) do
    scope = conn.assigns.current_scope

    with {:ok, attrs} <- body(conn, @editable),
         {:ok, character} <-
           Characters.create_character(scope.campaign, scope.discord_user_id, attrs) do
      ApiResponse.success(conn, project(character), status: 201)
    else
      {:error, reason} -> ApiResponse.domain_error(conn, reason, @fields)
    end
  end

  def update(conn, _params), do: mutate(conn, :update)
  def set_flag(conn, _params), do: mutate(conn, :set_flag)
  def clear_flag(conn, _params), do: mutate(conn, :clear_flag)

  defp mutate(conn, operation) do
    scope = conn.assigns.current_scope

    allowed =
      case operation do
        :update -> @editable ++ ["state_version"]
        :set_flag -> ["state_version", "type", "value", "player_visible"]
        :clear_flag -> ["state_version"]
      end

    with {:ok, params} <- body(conn, allowed),
         {:ok, version} <- ApiParams.version(params["state_version"]),
         {:ok, character} <-
           Characters.get_character(scope.campaign, scope.discord_user_id, conn.path_params["id"]),
         :ok <- expected_version(character, version),
         {:ok, updated} <- apply_mutation(operation, conn, character, params) do
      ApiResponse.success(conn, project(updated))
    else
      {:error, reason} -> ApiResponse.domain_error(conn, reason, @fields)
    end
  end

  defp apply_mutation(operation, conn, character, params) do
    scope = conn.assigns.current_scope
    opts = [expected_character: character]

    case operation do
      :update ->
        Characters.update_character(
          scope.campaign,
          scope.discord_user_id,
          character.id,
          Map.take(params, @editable),
          opts
        )

      :set_flag ->
        Characters.set_flag(
          scope.campaign,
          scope.discord_user_id,
          character.id,
          conn.path_params["key"],
          Map.delete(params, "state_version"),
          opts
        )

      :clear_flag ->
        Characters.clear_flag(
          scope.campaign,
          scope.discord_user_id,
          character.id,
          conn.path_params["key"],
          opts
        )
    end
  end

  defp expected_version(%{state_version: version}, version), do: :ok
  defp expected_version(_, _), do: {:error, :stale_character}

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

  defp project(character) do
    %{
      id: ApiResponse.id(character.id),
      campaign_id: ApiResponse.id(character.campaign_id),
      name: character.name,
      discord_user_id: ApiResponse.id(character.discord_user_id),
      flags: character.flags,
      state_version: character.state_version,
      inserted_at: ApiResponse.timestamp(character.inserted_at),
      updated_at: ApiResponse.timestamp(character.updated_at)
    }
  end
end
