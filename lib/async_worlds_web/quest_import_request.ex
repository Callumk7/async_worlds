defmodule AsyncWorldsWeb.QuestImportRequest do
  @moduledoc "Authenticates and reads bounded, unparsed quest JSON before Plug.Parsers."
  import Plug.Conn
  alias AsyncWorlds.Campaigns

  @max_bytes 1_048_576

  def init(opts), do: opts

  def call(
        %{method: "POST", path_info: ["api", "campaigns", guild, "quests", "import"]} = conn,
        _
      ) do
    with {:ok, dm_id} <- authenticate(conn),
         {:ok, campaign} <- Campaigns.authorize_dm(guild, dm_id) do
      conn = conn |> assign(:import_campaign, campaign) |> assign(:import_dm_id, dm_id)

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
    else
      {:error, :unauthenticated} ->
        conn |> put_resp_header("www-authenticate", "Bearer") |> error(401, "unauthenticated")

      {:error, _} ->
        error(conn, 404, "not_found")
    end
  end

  def call(conn, _), do: conn

  defp authenticate(conn) do
    config = Application.get_env(:async_worlds, :quest_import_api, [])
    token = Keyword.get(config, :token)
    dm_id = Keyword.get(config, :dm_user_id)

    with true <- is_binary(token) and byte_size(token) >= 32 and is_binary(dm_id),
         [header] <- get_req_header(conn, "authorization"),
         [scheme, supplied] <- String.split(header, " ", parts: 2),
         true <- String.downcase(scheme) == "bearer",
         true <-
           Plug.Crypto.secure_compare(
             :crypto.hash(:sha256, supplied),
             :crypto.hash(:sha256, token)
           ) do
      {:ok, dm_id}
    else
      _ -> {:error, :unauthenticated}
    end
  end

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
