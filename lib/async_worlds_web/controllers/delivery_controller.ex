defmodule AsyncWorldsWeb.DeliveryController do
  use AsyncWorldsWeb, :controller
  alias AsyncWorlds.DM.Deliveries
  alias AsyncWorlds.Discord.Snowflake
  alias AsyncWorldsWeb.{ApiParams, ApiRequest, ApiResponse}

  @statuses %{
    "pending" => :pending,
    "sending" => :sending,
    "sent" => :sent,
    "failed" => :failed,
    "ambiguous" => :ambiguous
  }
  @kinds %{"public" => :public, "private" => :private}

  def index(conn, _params) do
    with :ok <- ApiRequest.query(conn, ~w(status kind tick_id recipient_id before_id)),
         {:ok, filters} <- filters(conn.query_params),
         {:ok, deliveries} <-
           Deliveries.search_deliveries(conn.assigns.current_scope, filters, 51) do
      page = Enum.take(deliveries, 50)

      ApiResponse.success(conn, Enum.map(page, &project/1),
        meta: %{
          type: "cursor",
          page_size: 50,
          next_before_id:
            if(length(deliveries) > 50, do: ApiResponse.id(List.last(page).id), else: nil)
        }
      )
    else
      {:error, reason} -> ApiResponse.domain_error(conn, reason)
    end
  end

  def show(conn, _params) do
    with :ok <- ApiRequest.query(conn, []),
         {:ok, id} <- ApiRequest.resource_id(conn),
         {:ok, delivery} <- Deliveries.fetch_delivery(conn.assigns.current_scope, id) do
      ApiResponse.success(conn, project(delivery))
    else
      {:error, reason} -> ApiResponse.domain_error(conn, reason)
    end
  end

  def retry(conn, _params) do
    with {:ok, params} <- ApiRequest.body(conn, ~w(generation confirm_ambiguous)),
         {:ok, id} <- ApiRequest.resource_id(conn),
         {:ok, generation} <- ApiParams.version(params["generation"]),
         {:ok, confirm} <- confirmation(params["confirm_ambiguous"]),
         {:ok, delivery} <-
           Deliveries.retry_delivery(conn.assigns.current_scope, id, generation,
             confirm_ambiguous: confirm
           ) do
      ApiResponse.success(conn, project(delivery))
    else
      {:error, reason} -> ApiResponse.domain_error(conn, reason)
    end
  end

  defp confirmation(nil), do: {:ok, false}
  defp confirmation(value) when is_boolean(value), do: {:ok, value}
  defp confirmation(_), do: {:error, :invalid_parameters}

  defp filters(params) do
    Enum.reduce_while(params, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      parsed =
        case key do
          "status" -> enum(@statuses, value)
          "kind" -> enum(@kinds, value)
          "recipient_id" -> Snowflake.cast(value)
          _ -> ApiParams.id(value)
        end

      case parsed do
        {:ok, value} ->
          field =
            Map.fetch!(
              %{
                "status" => :status,
                "kind" => :kind,
                "tick_id" => :tick_id,
                "recipient_id" => :recipient_id,
                "before_id" => :before_id
              },
              key
            )

          {:cont, {:ok, Map.put(acc, field, value)}}

        _ ->
          {:halt, {:error, :invalid_filter}}
      end
    end)
  end

  defp enum(values, value) do
    case Map.fetch(values, value) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, :invalid_filter}
    end
  end

  defp project(d) do
    %{
      id: ApiResponse.id(d.id),
      tick_id: ApiResponse.id(d.tick_id),
      kind: d.kind,
      recipient_id: ApiResponse.id(d.recipient_id),
      content: d.content,
      status: d.status,
      generation: d.generation,
      attempts: d.attempts,
      error_class: d.error_class,
      inserted_at: ApiResponse.timestamp(d.inserted_at),
      started_at: ApiResponse.timestamp(d.started_at),
      sent_at: ApiResponse.timestamp(d.sent_at)
    }
  end
end
