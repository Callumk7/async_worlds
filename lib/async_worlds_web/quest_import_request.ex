defmodule AsyncWorldsWeb.QuestImportRequest do
  @moduledoc "Reads bounded, unparsed quest JSON after ApiAuth and before Plug.Parsers."
  import Plug.Conn

  @max_bytes 1_048_576

  def init(opts), do: opts

  def call(
        %{method: "POST", path_info: ["api", "campaigns", guild, "quests", "import"]} = conn,
        _
      ) do
    %{campaign: %{discord_guild_id: ^guild}, discord_user_id: _dm_id} = conn.assigns.current_scope

    case get_req_header(conn, "content-type") do
      [type] ->
        if String.downcase(String.trim(hd(String.split(type, ";")))) == "application/json" do
          read_json(conn, [], 0)
        else
          error(conn, 415, "unsupported_media_type")
        end

      _ ->
        error(conn, 415, "unsupported_media_type")
    end
  end

  def call(conn, _), do: conn

  defp read_json(conn, chunks, size) do
    case read_body(conn, length: 65_536, read_length: 65_536, read_timeout: 5_000) do
      {status, chunk, conn} when status in [:ok, :more] ->
        size = size + byte_size(chunk)

        cond do
          size > @max_bytes ->
            error(conn, 413, "payload_too_large")

          status == :more ->
            read_json(conn, [chunk | chunks], size)

          true ->
            body = chunks |> Enum.reverse([chunk]) |> IO.iodata_to_binary()
            # Skip general JSON decoding, which would discard duplicate object keys.
            conn |> Map.put(:body_params, %{}) |> assign(:quest_import_json, body)
        end

      {:error, _} ->
        error(conn, 400, "body_read_failed")
    end
  end

  defp error(conn, status, code) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{error: %{code: code}}))
    |> halt()
  end
end
