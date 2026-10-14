defmodule AsyncWorldsWeb.DeliveryControllerTest do
  use AsyncWorldsWeb.ConnCase, async: false
  import AsyncWorlds.HistoryFixtures
  alias AsyncWorlds.{Deliveries, Repo}
  alias AsyncWorlds.Ticks.Publication
  @token String.duplicate("d", 32)

  setup do
    previous = Application.get_env(:async_worlds, :dm_api)
    Application.put_env(:async_worlds, :dm_api, token: @token, dm_user_id: "22002")

    on_exit(fn ->
      if previous,
        do: Application.put_env(:async_worlds, :dm_api, previous),
        else: Application.delete_env(:async_worlds, :dm_api)
    end)

    campaign = history_campaign()
    tick = legacy_publication(campaign, 1)

    {:ok, delivery} =
      Deliveries.enqueue(campaign.id, tick.id, %{
        key: "test",
        kind: :private,
        recipient_id: "44004",
        content: "Saved message"
      })

    %{campaign: campaign, tick: tick, delivery: delivery, base: "/api/campaigns/11001/deliveries"}
  end

  defp request(method, path, body \\ %{}) do
    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> @token)
      |> put_req_header("content-type", "application/json")

    case method do
      :get -> get(conn, path)
      :post -> post(conn, path, Jason.encode!(body))
    end
  end

  test "inspection filters and cursor pages are bounded and redact raw errors", c do
    Repo.update!(
      Ecto.Changeset.change(c.delivery, status: :failed, last_error: "secret credential")
    )

    [data] =
      json_response(
        request(:get, c.base <> "?status=failed&kind=private&recipient_id=44004"),
        200
      )["data"]

    assert data["content"] == "Saved message"
    refute Map.has_key?(data, "last_error")
    refute Map.has_key?(data, "guard")

    assert json_response(request(:get, c.base <> "?status=unknown"), 422)["error"]["code"] ==
             "invalid_filter"

    for n <- 1..51 do
      {:ok, _} =
        Deliveries.enqueue(c.campaign.id, c.tick.id, %{
          key: "page-#{n}",
          kind: :public,
          recipient_id: "33003",
          content: "Message"
        })
    end

    first = json_response(request(:get, c.base <> "?kind=public"), 200)
    assert length(first["data"]) == 50
    cursor = first["meta"]["next_before_id"]
    second = json_response(request(:get, c.base <> "?kind=public&before_id=#{cursor}"), 200)
    assert length(second["data"]) == 1
    refute hd(second["data"])["id"] in Enum.map(first["data"], & &1["id"])
  end

  test "targeted retries require generation and explicit ambiguous confirmation without republishing",
       c do
    delivery =
      Repo.update!(Ecto.Changeset.change(c.delivery, status: :ambiguous, error_class: :ambiguous))

    path = c.base <> "/#{delivery.id}/retry"
    publications = Repo.all(Publication)
    assert json_response(request(:post, path), 428)["error"]["code"] == "precondition_required"

    assert json_response(request(:post, path, %{generation: 0}), 409)["error"]["code"] ==
             "confirmation_required"

    assert json_response(request(:post, path, %{generation: 0, confirm_ambiguous: "true"}), 422)[
             "error"
           ]["code"] == "invalid_parameters"

    data =
      json_response(request(:post, path, %{generation: 0, confirm_ambiguous: true}), 200)["data"]

    assert data["generation"] == 1
    assert data["status"] == "pending"

    assert json_response(request(:post, path, %{generation: 0, confirm_ambiguous: true}), 409)[
             "error"
           ]["code"] == "stale_delivery"

    assert Repo.all(Publication) == publications
    Repo.update!(Ecto.Changeset.change(Repo.reload!(delivery), status: :sent))

    assert json_response(request(:post, path, %{generation: 1}), 409)["error"]["code"] ==
             "not_retryable"
  end

  test "foreign deliveries and revoked ownership are concealed", c do
    other = history_campaign("11002", "22002")
    tick = legacy_publication(other, 1)

    {:ok, foreign} =
      Deliveries.enqueue(other.id, tick.id, %{
        key: "foreign",
        kind: :public,
        recipient_id: "33003",
        content: "Foreign"
      })

    assert json_response(request(:get, c.base <> "/#{foreign.id}"), 404)["error"]["code"] ==
             "not_found"

    assert json_response(request(:post, c.base <> "/#{foreign.id}/retry", %{generation: 0}), 404)[
             "error"
           ]["code"] == "not_found"

    Repo.update!(Ecto.Changeset.change(c.campaign, dm_user_id: "22003"))
    assert json_response(request(:get, c.base), 404)["error"]["code"] == "not_found"
  end
end
