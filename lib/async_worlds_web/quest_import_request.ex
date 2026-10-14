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
          error(conn, :unsupported_media_type)
        end

      _ ->
        error(conn, :unsupported_media_type)
    end
  end

  def call(conn, _), do: conn

  defp read_json(conn, chunks, size) do
    case read_body(conn, length: 65_536, read_length: 65_536, read_timeout: 5_000) do
      {status, chunk, conn} when status in [:ok, :more] ->
        size = size + byte_size(chunk)

        cond do
          size > @max_bytes ->
            error(conn, :payload_too_large)

          status == :more ->
            read_json(conn, [chunk | chunks], size)

          true ->
            body = chunks |> Enum.reverse([chunk]) |> IO.iodata_to_binary()
            # Skip general JSON decoding, which would discard duplicate object keys.
            conn |> Map.put(:body_params, %{}) |> assign(:quest_import_json, body)
        end

      {:error, _} ->
        error(conn, :body_read_failed)
    end
  end

  defp error(conn, reason), do: conn |> AsyncWorldsWeb.ApiResponse.error(reason) |> halt()
end
