defmodule AsyncWorldsWeb.ApiConventionsTest do
  use AsyncWorldsWeb.ConnCase, async: true
  alias AsyncWorldsWeb.{ApiParams, ApiResponse, ApiTokens, Endpoint}
  alias AsyncWorlds.Campaigns.Campaign
  alias AsyncWorlds.Clocks.Clock

  defp scope do
    %{
      campaign: %Campaign{
        id: 1,
        discord_guild_id: "123",
        dm_user_id: "456",
        public_channel_id: "789"
      },
      discord_user_id: "456"
    }
  end

  test "success envelopes carry projected data, optional metadata and creation status" do
    conn = ApiResponse.success(build_conn(), %{id: ApiResponse.id(123)}, status: 201)
    assert json_response(conn, 201) == %{"data" => %{"id" => "123"}}
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert build_conn() |> ApiResponse.success(nil) |> json_response(200) == %{"data" => nil}
    meta = %{pagination: ApiParams.page_meta(1, 20, true)}

    assert %{
             "data" => [],
             "meta" => %{"pagination" => %{"next_page" => 2, "previous_page" => nil}}
           } =
             build_conn() |> ApiResponse.success([], meta: meta) |> json_response(200)
  end

  test "raw internal records, nested schemas, changesets and exceptions cannot become success payloads" do
    for data <- [
          %Clock{name: "PRIVATE"},
          [%{record: %Campaign{dm_user_id: "SECRET"}}],
          Ecto.Changeset.change(%Clock{}),
          RuntimeError.exception("SECRET"),
          %{<<255>> => "bad key"}
        ] do
      conn = ApiResponse.success(build_conn(), data)
      assert json_response(conn, 500) == %{"error" => %{"code" => "internal_error"}}
      refute conn.resp_body =~ "SECRET"
      refute conn.resp_body =~ "PRIVATE"
    end
  end

  test "public domain errors use fixed statuses and conceal forbidden resources" do
    for reason <- [:not_found, :unauthorized, :invalid_campaign, :invalid_scope] do
      assert build_conn() |> ApiResponse.domain_error(reason) |> json_response(404) == %{
               "error" => %{"code" => "not_found"}
             }
    end

    for reason <- [
          :stale_character,
          :stale_clock,
          :stale_draft,
          :stale_delivery,
          :stale_working_copy,
          :stale_campaign,
          :idempotency_conflict,
          :tick_locked,
          :confirmation_required
        ] do
      assert build_conn() |> ApiResponse.domain_error(reason) |> json_response(409) == %{
               "error" => %{"code" => Atom.to_string(reason)}
             }
    end

    assert build_conn()
           |> ApiResponse.domain_error({:invalid_transition, :private_state, "secret operation"})
           |> json_response(409) == %{"error" => %{"code" => "invalid_transition"}}

    assert build_conn() |> ApiResponse.error(:invalid_parameters) |> json_response(422)
    assert build_conn() |> ApiResponse.error(:precondition_required) |> json_response(428)
  end

  test "authentication challenge and transport errors use the shared envelope" do
    conn = ApiResponse.error(build_conn(), :unauthenticated)
    assert json_response(conn, 401) == %{"error" => %{"code" => "unauthenticated"}}
    assert get_resp_header(conn, "www-authenticate") == ["Bearer"]

    for {reason, status} <- [
          {:invalid_json, 400},
          {:payload_too_large, 413},
          {:unsupported_media_type, 415}
        ] do
      assert build_conn() |> ApiResponse.error(reason) |> json_response(status) == %{
               "error" => %{"code" => Atom.to_string(reason)}
             }
    end
  end

  test "unknown errors and exception messages are never serialized" do
    for reason <- [
          :private_internal_reason,
          {:database, "SECRET"},
          RuntimeError.exception("SECRET"),
          [%{secret: "SECRET"}]
        ] do
      conn = ApiResponse.domain_error(build_conn(), reason)
      assert json_response(conn, 500) == %{"error" => %{"code" => "internal_error"}}
    end

    assert build_conn()
           |> ApiResponse.error(:unknown, details: [%{message: "SECRET"}])
           |> json_response(500) == %{"error" => %{"code" => "internal_error"}}
  end

  test "changeset diagnostics are field-whitelisted and never interpolate input values" do
    changeset =
      %Clock{}
      |> Ecto.Changeset.change(name: "SECRET")
      |> Ecto.Changeset.add_error(:name, "SECRET %{value}",
        validation: :required,
        value: "SECRET"
      )
      |> Ecto.Changeset.add_error(:triggers, "PRIVATE triggers", validation: :required)

    assert build_conn() |> ApiResponse.domain_error(changeset, [:name]) |> json_response(422) ==
             %{
               "error" => %{
                 "code" => "invalid_parameters",
                 "details" => [%{"field" => "name", "code" => "required"}]
               }
             }

    assert build_conn() |> ApiResponse.domain_error(changeset) |> json_response(422) ==
             %{"error" => %{"code" => "invalid_parameters", "details" => []}}
  end

  test "wire identifiers and timestamps are explicitly projected" do
    assert ApiResponse.id(nil) == nil
    assert ApiResponse.id(9_223_372_036_854_775_807) == "9223372036854775807"
    assert ApiResponse.id("18446744073709551615") == "18446744073709551615"
    assert ApiResponse.timestamp(nil) == nil
    assert ApiResponse.timestamp(~U[2026-10-14 00:00:00Z]) == "2026-10-14T00:00:00Z"
  end

  test "IDs, pages and versions parse strictly without silently defaulting preconditions" do
    assert {:ok, 1} = ApiParams.page(nil)
    assert {:ok, 100_000} = ApiParams.page("100000")
    assert {:error, :invalid_page} = ApiParams.page("100001")
    assert {:ok, 9_223_372_036_854_775_807} = ApiParams.id("9223372036854775807")
    assert {:error, :invalid_id} = ApiParams.id("9223372036854775808")
    assert {:error, :precondition_required} = ApiParams.version(nil)
    assert {:ok, 0} = ApiParams.version("0")

    for value <- ["-1", "+1", " 1", "1x", "1.0", 1.0, %{}, String.duplicate("9", 100)] do
      assert {:error, _} = ApiParams.id(value)
      assert {:error, _} = ApiParams.page(value)
      assert {:error, _} = ApiParams.version(value)
    end

    uuid = Ecto.UUID.generate()
    assert {:ok, ^uuid} = ApiParams.uuid(uuid)
    assert {:error, :precondition_required} = ApiParams.uuid(nil)
    assert {:error, :invalid_parameters} = ApiParams.uuid("bad")
  end

  test "Idempotency-Key is singular, generic and bounded" do
    uuid = Ecto.UUID.generate()

    assert {:ok, ^uuid} =
             build_conn()
             |> put_req_header("idempotency-key", uuid)
             |> ApiParams.idempotency_key()

    assert {:error, :precondition_required} = ApiParams.idempotency_key(build_conn())

    for key <- ["", " ", <<0>>, <<255>>, String.duplicate("x", 201)] do
      assert {:error, :invalid_idempotency_key} =
               build_conn()
               |> put_req_header("idempotency-key", key)
               |> ApiParams.idempotency_key()
    end

    conn = %{build_conn() | req_headers: [{"idempotency-key", "one"}, {"idempotency-key", "two"}]}
    assert {:error, :invalid_idempotency_key} = ApiParams.idempotency_key(conn)
  end

  test "cursor tokens preserve ceiling/boundary and reject tampering, scope/filter reuse and expiry" do
    cursor = %{direction: :next, anchor: 10, ceiling: 20}
    s = scope()
    resource = "journals:mine"
    {:ok, token} = ApiTokens.cursor(s, resource, cursor)
    assert {:ok, ^cursor} = ApiTokens.decode_cursor(s, resource, token)
    assert {:ok, nil} = ApiTokens.decode_cursor(s, resource, nil)
    assert {:ok, nil} = ApiTokens.cursor(s, resource, nil)
    assert {:error, :invalid_cursor} = ApiTokens.cursor(s, resource, %{cursor | ceiling: 9})
    assert {:error, :invalid_cursor} = ApiTokens.decode_cursor(s, "journals:public", token)

    assert {:error, :invalid_cursor} =
             ApiTokens.decode_cursor(%{s | discord_user_id: "457"}, resource, token)

    for token <- [token <> "bad", "garbage", String.duplicate("x", 4097)] do
      assert {:error, :invalid_cursor} = ApiTokens.decode_cursor(s, resource, token)
    end

    {:ok, payload} = Phoenix.Token.verify(Endpoint, "http-api-cursor-v1", token, max_age: 86400)

    expired =
      Phoenix.Token.sign(Endpoint, "http-api-cursor-v1", payload,
        signed_at: System.system_time(:second) - 100_000
      )

    assert {:error, :invalid_cursor} = ApiTokens.decode_cursor(s, resource, expired)
  end

  test "clock snapshot tokens reveal no record fields and return the loaded record for the domain's locked comparison" do
    s = scope()
    clock = %Clock{id: 1, campaign_id: 1, name: "PRIVATE", filled: 0, segments: 4}
    token = ApiTokens.clock_snapshot(s, clock)
    {:ok, payload} = Phoenix.Token.verify(Endpoint, "http-api-clock-v1", token, max_age: 86400)
    assert Enum.sort(Map.keys(payload)) == [:digest, :id, :scope]
    refute inspect(payload) =~ "PRIVATE"
    assert {:ok, ^clock} = ApiTokens.verify_clock_snapshot(s, clock, token)
    assert {:error, :precondition_required} = ApiTokens.verify_clock_snapshot(s, clock, nil)

    assert {:error, :stale_clock} =
             ApiTokens.verify_clock_snapshot(s, %{clock | filled: 1}, token)

    assert {:error, :stale_clock} = ApiTokens.verify_clock_snapshot(s, %{clock | id: 2}, token)

    assert {:error, :stale_clock} =
             ApiTokens.verify_clock_snapshot(%{s | discord_user_id: "457"}, clock, token)

    assert {:error, :stale_clock} = ApiTokens.verify_clock_snapshot(s, clock, token <> "bad")
    changed_scope = %{s | campaign: %{s.campaign | public_channel_id: "790"}}
    assert {:error, :stale_clock} = ApiTokens.verify_clock_snapshot(changed_scope, clock, token)
  end
end
