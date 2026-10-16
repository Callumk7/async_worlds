defmodule AsyncWorldsWeb.ApiResponse do
  @moduledoc "Shared JSON envelopes and bounded public domain-error mappings. Controllers project records explicitly."
  import Plug.Conn

  @not_found [:not_found, :unauthorized, :invalid_campaign, :invalid_scope]
  @conflicts [
    :invalid_transition,
    :active_tick,
    :active_quest,
    :tick_locked,
    :tick_closed,
    :already_published,
    :completed,
    :already_paired,
    :not_filled,
    :not_active,
    :not_retryable,
    :confirmation_required,
    :stale_campaign,
    :stale_character,
    :stale_clock,
    :stale_draft,
    :stale_delivery,
    :stale_working_copy,
    :stale_base_revision,
    :stale_progression,
    :stale_identity,
    :stale_input,
    :stale_live_state,
    :stale_component,
    :idempotency_conflict,
    :delivery_conflict,
    :location_linked,
    :location_cycle,
    :hierarchy_too_deep,
    :faction_has_memberships
  ]
  @invalid [
    :invalid_id,
    :invalid_flag,
    :invalid_delta,
    :invalid_source,
    :invalid_reason,
    :invalid_edit,
    :invalid_payload,
    :invalid_definition,
    :invalid_quest,
    :invalid_clock_name,
    :invalid_node,
    :invalid_filter,
    :invalid_page,
    :invalid_cursor,
    :invalid_journal_input,
    :invalid_idempotency_key,
    :unsupported_edit,
    :immutable_content_id,
    :self_link,
    :unavailable_choice,
    :invalid_document,
    :invalid_clock_refs,
    :invalid_parameters
  ]
  @missing [:no_tick, :no_quest, :no_draft, :not_closed, :not_published]

  def success(conn, data, opts \\ []) do
    payload = %{data: data}

    payload =
      if Keyword.has_key?(opts, :meta), do: Map.put(payload, :meta, opts[:meta]), else: payload

    if public_json?(payload) do
      send_json(conn, Keyword.get(opts, :status, 200), payload)
    else
      error(conn, :internal_error)
    end
  end

  def error(conn, reason, opts \\ []) do
    {status, code} = classification(reason)
    error = %{code: code}
    details = Keyword.get(opts, :details)

    error =
      if status in 400..499 and is_list(details) and public_json?(details),
        do: Map.put(error, :details, details),
        else: error

    conn = if status == 401, do: put_resp_header(conn, "www-authenticate", "Bearer"), else: conn
    send_json(conn, status, %{error: error})
  end

  @doc "Safe error body for Phoenix's JSON exception renderer, without connection side effects."
  def error_payload(reason), do: %{error: %{code: elem(classification(reason), 1)}}

  @doc "Changeset errors expose whitelisted field names and fixed codes, never input values/messages/options."
  def domain_error(conn, reason, fields \\ [])

  def domain_error(conn, %Ecto.Changeset{} = changeset, fields) do
    details =
      for {field, {_message, opts}} <- changeset.errors, field in fields do
        %{field: Atom.to_string(field), code: validation_code(opts)}
      end

    error(conn, :invalid_parameters, details: details)
  end

  def domain_error(conn, {:validation, _errors}, _fields), do: error(conn, :invalid_document)
  def domain_error(conn, reason, _fields), do: error(conn, reason)

  defp classification(:unauthenticated), do: {401, "unauthenticated"}
  defp classification(reason) when reason in @not_found, do: {404, "not_found"}
  defp classification(reason) when reason in @missing, do: {404, Atom.to_string(reason)}
  defp classification(reason) when reason in @conflicts, do: {409, Atom.to_string(reason)}
  defp classification({:invalid_transition, _, _}), do: {409, "invalid_transition"}
  defp classification(reason) when reason in @invalid, do: {422, Atom.to_string(reason)}
  defp classification(:precondition_required), do: {428, "precondition_required"}
  defp classification(:forbidden), do: {403, "forbidden"}
  defp classification(:bad_request), do: {400, "bad_request"}
  defp classification(:method_not_allowed), do: {405, "method_not_allowed"}
  defp classification(:invalid_json), do: {400, "invalid_json"}
  defp classification(:body_read_failed), do: {400, "body_read_failed"}
  defp classification(:payload_too_large), do: {413, "payload_too_large"}
  defp classification(:unsupported_media_type), do: {415, "unsupported_media_type"}
  defp classification(_), do: {500, "internal_error"}

  defp validation_code(opts) do
    case {opts[:constraint], opts[:validation]} do
      {:unique, _} -> "already_taken"
      {_, :required} -> "required"
      {_, :length} -> "invalid_length"
      {_, :number} -> "invalid_number"
      _ -> "invalid"
    end
  end

  @doc "Explicit wire conversion: database IDs are strings, versions/counts remain integers."
  def id(nil), do: nil
  def id(value) when is_integer(value), do: Integer.to_string(value)
  def id(value) when is_binary(value), do: value

  def timestamp(nil), do: nil
  def timestamp(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp send_json(conn, status, payload) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(payload))
  end

  # Never serialize Ecto schemas/changesets, exceptions or arbitrary internal structs.
  defp public_json?(%{__struct__: _}), do: false

  defp public_json?(value) when is_map(value),
    do:
      Enum.all?(value, fn {key, item} ->
        ((is_binary(key) and String.valid?(key)) or is_atom(key)) and public_json?(item)
      end)

  defp public_json?(value) when is_list(value), do: Enum.all?(value, &public_json?/1)
  defp public_json?(value) when is_binary(value), do: String.valid?(value)
  defp public_json?(value) when is_number(value) or is_atom(value), do: true
  defp public_json?(_), do: false
end
