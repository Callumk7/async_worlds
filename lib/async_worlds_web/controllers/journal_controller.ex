defmodule AsyncWorldsWeb.JournalController do
  use AsyncWorldsWeb, :controller
  alias AsyncWorlds.Journals
  alias AsyncWorldsWeb.{ApiParams, ApiRequest, ApiResponse, ApiTokens}
  @delete_salt "http-journal-delete-v1"

  def index(conn, _params) do
    with :ok <- ApiRequest.query(conn, ~w(cursor)),
         {:ok, id} <- ApiRequest.resource_id(conn),
         {:ok, cursor} <- cursor(conn, id),
         {:ok, page} <- Journals.dm_list_entries(conn.assigns.current_scope, id, cursor) do
      ApiResponse.success(conn, Enum.map(page.entries, &summary/1),
        meta: %{
          type: "cursor",
          page_size: 10,
          next_cursor: sign_cursor(conn, id, page.next),
          previous_cursor: sign_cursor(conn, id, page.previous)
        }
      )
    else
      {:error, reason} -> ApiResponse.domain_error(conn, reason)
    end
  end

  def show(conn, _params) do
    with :ok <- ApiRequest.query(conn, []),
         {:ok, id} <- ApiRequest.resource_id(conn),
         {:ok, %{entry: entry, delete_binding: binding}} <-
           Journals.dm_get_entry(conn.assigns.current_scope, id) do
      data =
        summary(entry)
        |> Map.merge(%{
          body: entry.body,
          character_id: ApiResponse.id(entry.character_id),
          author_id: ApiResponse.id(entry.author_discord_user_id),
          origin: entry.origin,
          delete_token: Phoenix.Token.sign(AsyncWorldsWeb.Endpoint, @delete_salt, binding)
        })

      ApiResponse.success(conn, data)
    else
      {:error, reason} -> ApiResponse.domain_error(conn, reason)
    end
  end

  def create(conn, _params) do
    with {:ok, params} <- ApiRequest.body(conn, ~w(title body visibility)),
         {:ok, id} <- ApiRequest.resource_id(conn),
         {:ok, key} <- ApiParams.idempotency_key(conn),
         {:ok, outcome} <-
           Journals.create_dm_entry(
             conn.assigns.current_scope,
             id,
             key,
             Map.take(params, ~w(title body)),
             Map.get(params, "visibility", "private")
           ) do
      ApiResponse.success(conn, %{
        receipt_id: ApiResponse.id(outcome.id),
        entry_id: ApiResponse.id(outcome.entry_id),
        state: outcome.state,
        visibility: outcome.visibility
      })
    else
      {:error, reason} -> ApiResponse.domain_error(conn, reason)
    end
  end

  def delete(conn, _params) do
    with {:ok, params} <- ApiRequest.body(conn, ~w(delete_token confirm)),
         {:ok, id} <- ApiRequest.resource_id(conn),
         :ok <- confirmation(params["confirm"]),
         {:ok, binding} <- verify(@delete_salt, params["delete_token"], :stale_component),
         {:ok, outcome} <- Journals.dm_delete_entry(conn.assigns.current_scope, id, binding) do
      ApiResponse.success(conn, %{id: ApiResponse.id(id), state: outcome})
    else
      {:error, reason} -> ApiResponse.domain_error(conn, reason)
    end
  end

  defp summary(entry),
    do: %{
      id: ApiResponse.id(entry.id),
      title: entry.title,
      visibility: entry.visibility,
      inserted_at: ApiResponse.timestamp(entry.inserted_at)
    }

  defp confirmation(true), do: :ok
  defp confirmation(value) when value in [nil, false], do: {:error, :confirmation_required}
  defp confirmation(_), do: {:error, :invalid_parameters}

  defp cursor(conn, id) do
    ApiTokens.decode_cursor(
      conn.assigns.current_scope,
      "character:#{id}:journals",
      conn.query_params["cursor"]
    )
  end

  defp sign_cursor(conn, id, cursor) do
    {:ok, token} =
      ApiTokens.cursor(conn.assigns.current_scope, "character:#{id}:journals", cursor)

    token
  end

  defp verify(_salt, nil, _reason), do: {:error, :precondition_required}

  defp verify(salt, token, reason) when is_binary(token) and byte_size(token) <= 4096 do
    case Phoenix.Token.verify(AsyncWorldsWeb.Endpoint, salt, token, max_age: 86_400) do
      {:ok, value} -> {:ok, value}
      _ -> {:error, reason}
    end
  end

  defp verify(_, _, reason), do: {:error, reason}
end
