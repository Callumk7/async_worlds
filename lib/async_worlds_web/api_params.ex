defmodule AsyncWorldsWeb.ApiParams do
  @moduledoc "Strict HTTP parameter parsing; never infer mutation preconditions or accept actor identities from input."
  import Plug.Conn, only: [get_req_header: 2]
  @max_id 9_223_372_036_854_775_807

  def id(value), do: integer(value, 1, @max_id, :invalid_id)
  def page(nil), do: {:ok, 1}
  def page(value), do: integer(value, 1, 100_000, :invalid_page)

  @doc "Missing mutation versions must fail, not silently use the latest persisted value."
  def version(nil), do: {:error, :precondition_required}
  def version(value), do: integer(value, 0, @max_id, :invalid_parameters)

  def uuid(nil), do: {:error, :precondition_required}

  def uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> {:ok, id}
      _ -> {:error, :invalid_parameters}
    end
  end

  @doc "Creation requests requiring idempotency use one Idempotency-Key header, not body/actor fields."
  def idempotency_key(conn) do
    case get_req_header(conn, "idempotency-key") do
      [key] when byte_size(key) in 1..200 ->
        if String.valid?(key) and String.trim(key) != "" and not String.contains?(key, <<0>>),
          do: {:ok, key},
          else: {:error, :invalid_idempotency_key}

      [] ->
        {:error, :precondition_required}

      _ ->
        {:error, :invalid_idempotency_key}
    end
  end

  @doc "Page-based collections have fixed domain page sizes; HTTP never expands them."
  def page_meta(page, page_size, more?)
      when is_integer(page) and page > 0 and is_integer(page_size) and page_size > 0 and
             is_boolean(more?) do
    %{
      type: "page",
      page: page,
      page_size: page_size,
      next_page: if(more?, do: page + 1, else: nil),
      previous_page: if(page > 1, do: page - 1, else: nil)
    }
  end

  defp integer(value, min, max, _reason) when is_integer(value) and value >= min and value <= max,
    do: {:ok, value}

  defp integer(value, min, max, reason) when is_binary(value) and byte_size(value) in 1..19 do
    # Decimal digits only: no signs, whitespace, exponent notation or trailing text.
    if Regex.match?(~r/\A[0-9]+\z/, value) do
      integer(String.to_integer(value), min, max, reason)
    else
      {:error, reason}
    end
  end

  defp integer(_, _, _, reason), do: {:error, reason}
end
