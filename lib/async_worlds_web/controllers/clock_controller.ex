defmodule AsyncWorldsWeb.ClockController do
  use AsyncWorldsWeb, :controller

  alias AsyncWorlds.DM.{Clocks, Tensions}
  alias AsyncWorldsWeb.{ApiParams, ApiResponse, ApiTokens}

  @fields [
    :name,
    :segments,
    :filled,
    :visibility,
    :background_rate,
    :paused,
    :triggers,
    :mode,
    :influences,
    :empty_description,
    :full_description
  ]
  @editable Enum.map(@fields, &Atom.to_string/1)

  def index(conn, _params) do
    scope = conn.assigns.current_scope

    with :ok <- query(conn),
         {:ok, clocks} <- Clocks.list_clocks(scope) do
      ApiResponse.success(conn, Enum.map(clocks, &project(scope, &1)))
    else
      {:error, reason} -> ApiResponse.domain_error(conn, reason, @fields)
    end
  end

  def show(conn, _params) do
    scope = conn.assigns.current_scope

    with :ok <- query(conn),
         {:ok, clock} <- load_clock(conn) do
      ApiResponse.success(conn, project(scope, clock))
    else
      {:error, reason} -> ApiResponse.domain_error(conn, reason, @fields)
    end
  end

  def create(conn, _params) do
    scope = conn.assigns.current_scope

    with {:ok, attrs} <- body(conn, @editable),
         :ok <- trigger_shape(attrs),
         {:ok, clock} <- Clocks.create_clock(scope, attrs) do
      ApiResponse.success(conn, project(scope, clock), status: 201)
    else
      {:error, reason} -> ApiResponse.domain_error(conn, reason, @fields)
    end
  end

  def create_for_tension(conn, _params) do
    scope = conn.assigns.current_scope

    with {:ok, attrs} <- body(conn, @editable),
         :ok <- trigger_shape(attrs),
         {:ok, id} <- resource_id(conn.path_params["id"]),
         {:ok, clock} <- Tensions.create_clock(scope, id, attrs, :http) do
      ApiResponse.success(conn, project(scope, clock), status: 201)
    else
      {:error, reason} -> ApiResponse.domain_error(conn, reason, @fields)
    end
  end

  def update(conn, _params), do: mutate(conn, :update)
  def associate(conn, _params), do: mutate(conn, :associate)
  def adjust(conn, _params), do: mutate(conn, :adjust)
  def pause(conn, _params), do: mutate(conn, :pause)
  def resume(conn, _params), do: mutate(conn, :resume)
  def reset(conn, _params), do: mutate(conn, :reset)
  def pair(conn, _params), do: mutate(conn, :pair)
  def unpair(conn, _params), do: mutate(conn, :unpair)

  defp mutate(conn, operation) do
    scope = conn.assigns.current_scope

    allowed =
      case operation do
        :update -> @editable
        :associate -> ["tension_id"]
        :adjust -> ["delta"]
        :pair -> ["partner_id", "partner_snapshot_token"]
        op when op in [:reset, :unpair] -> ["partner_snapshot_token"]
        _ -> []
      end

    with {:ok, params} <- body(conn, ["snapshot_token" | allowed]),
         :ok <- trigger_shape(params),
         {:ok, clock} <- load_clock(conn),
         {:ok, expected} <-
           ApiTokens.verify_clock_snapshot(scope, clock, params["snapshot_token"]),
         {:ok, result} <- apply_mutation(scope, operation, expected, params) do
      data =
        if is_list(result),
          do: Enum.map(result, &project(scope, &1)),
          else: project(scope, result)

      ApiResponse.success(conn, data)
    else
      {:error, reason} -> ApiResponse.domain_error(conn, reason, @fields)
    end
  end

  defp apply_mutation(scope, :update, clock, params),
    do: Clocks.edit_clock(scope, clock.id, Map.take(params, @editable), :http, clock)

  defp apply_mutation(scope, :associate, clock, %{"tension_id" => nil}),
    do: Tensions.associate_clock(scope, clock.id, nil, clock, :http)

  defp apply_mutation(scope, :associate, clock, %{"tension_id" => value}) do
    with {:ok, id} <- resource_id(value),
         do: Tensions.associate_clock(scope, clock.id, id, clock, :http)
  end

  defp apply_mutation(_scope, :associate, _clock, _params),
    do: {:error, :invalid_parameters}

  defp apply_mutation(scope, :adjust, clock, %{"delta" => delta}) when is_integer(delta),
    do: Clocks.adjust_clock(scope, clock.id, delta, :http, clock)

  defp apply_mutation(_scope, :adjust, _clock, _params), do: {:error, :invalid_delta}

  defp apply_mutation(scope, operation, clock, _params) when operation in [:pause, :resume],
    do: Clocks.edit_clock(scope, clock.id, %{paused: operation == :pause}, :http, clock)

  defp apply_mutation(scope, :pair, clock, params) do
    with {:ok, partner_id} <- resource_id(params["partner_id"]),
         {:ok, partner} <- Clocks.get_clock(scope, partner_id),
         {:ok, partner} <-
           ApiTokens.verify_clock_snapshot(scope, partner, params["partner_snapshot_token"]) do
      Clocks.pair_clocks(scope, clock.id, partner.id, :http, [clock, partner])
    end
  end

  defp apply_mutation(scope, operation, clock, params) when operation in [:reset, :unpair] do
    with {:ok, members} <- expected_members(scope, clock, params) do
      case operation do
        :reset -> Clocks.reset_clock(scope, clock.id, :http, members)
        :unpair -> Clocks.unpair_clock(scope, clock.id, :http, members)
      end
    end
  end

  defp expected_members(scope, %{racing_group: group} = clock, params) when not is_nil(group) do
    with {:ok, clocks} <- Clocks.list_clocks(scope),
         partner when not is_nil(partner) <-
           Enum.find(clocks, &(&1.racing_group == group and &1.id != clock.id)),
         {:ok, partner} <-
           ApiTokens.verify_clock_snapshot(scope, partner, params["partner_snapshot_token"]) do
      {:ok, [clock, partner]}
    else
      nil -> {:error, :stale_clock}
      {:error, reason} -> {:error, reason}
    end
  end

  defp expected_members(_scope, clock, params) do
    if Map.has_key?(params, "partner_snapshot_token"),
      do: {:error, :invalid_parameters},
      else: {:ok, [clock]}
  end

  defp load_clock(conn) do
    with {:ok, id} <- resource_id(conn.path_params["id"]),
         do: Clocks.get_clock(conn.assigns.current_scope, id)
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

  # cast_embed expects object children; reject malformed containers before Ecto.
  defp trigger_shape(%{"triggers" => triggers}) do
    if is_list(triggers) and Enum.all?(triggers, &is_map/1),
      do: :ok,
      else: {:error, :invalid_parameters}
  end

  defp trigger_shape(_), do: :ok

  defp project(scope, clock) do
    %{
      id: ApiResponse.id(clock.id),
      campaign_id: ApiResponse.id(clock.campaign_id),
      name: clock.name,
      tension_id: ApiResponse.id(clock.tension_id),
      association_revision: clock.association_revision,
      mode: Atom.to_string(clock.mode),
      influences: clock.influences,
      empty_description: clock.empty_description,
      full_description: clock.full_description,
      segments: clock.segments,
      filled: clock.filled,
      visibility: Atom.to_string(clock.visibility),
      background_rate: clock.background_rate,
      paused: clock.paused,
      completed: clock.completed,
      racing_group: clock.racing_group,
      triggers: Enum.map(clock.triggers, &project_trigger/1),
      inserted_at: ApiResponse.timestamp(clock.inserted_at),
      updated_at: ApiResponse.timestamp(clock.updated_at),
      snapshot_token: ApiTokens.clock_snapshot(scope, clock)
    }
  end

  defp project_trigger(trigger) do
    case trigger.type do
      type when type in [:notify_dm, :world_news] ->
        %{type: Atom.to_string(type), text: trigger.text}

      :start_clock ->
        %{type: "start_clock", clock_id: ApiResponse.id(trigger.clock_id)}

      :set_flag ->
        %{
          type: "set_flag",
          character_id: ApiResponse.id(trigger.character_id),
          key: trigger.key,
          flag: trigger.flag
        }

      :unlock_quest ->
        %{
          type: "unlock_quest",
          character_id: ApiResponse.id(trigger.character_id),
          quest_id: ApiResponse.id(trigger.quest_id)
        }
    end
  end
end
