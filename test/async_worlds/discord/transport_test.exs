defmodule AsyncWorlds.Discord.TransportTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  alias AsyncWorlds.Discord.{LogFilter, NostrumAdapter}

  test "Nostrum acknowledgment success is normalized to the adapter contract" do
    assert NostrumAdapter.normalize_acknowledgment({:ok}) == :ok

    assert NostrumAdapter.normalize_acknowledgment({:error, :transport_failure}) ==
             {:error, :transport_failure}
  end

  test "responses defer privately and disable automatic mentions" do
    assert NostrumAdapter.deferred_response() == %{type: 5, data: %{flags: 64}}

    assert NostrumAdapter.response_data("@everyone") == %{
             content: "@everyone",
             allowed_mentions: %{parse: []}
           }
  end

  test "followups retain private flags and mention suppression after Nostrum normalization" do
    content = "@everyone @here <@123> <@&456>"

    payload =
      content
      |> NostrumAdapter.followup_data()
      |> Nostrum.Api.Helpers.prepare_allowed_mentions()

    assert payload == %{
             content: content,
             flags: 64,
             allowed_mentions: %{parse: []}
           }

    # Original-response edits bypass Webhook.execute's option normalization.
    assert NostrumAdapter.response_data(content) == %{
             content: content,
             allowed_mentions: %{parse: []}
           }
  end

  test "public and private outbox payloads survive Nostrum normalization without mentions" do
    for kind <- [:public, :private] do
      delivery = %AsyncWorlds.Deliveries.Delivery{
        id: 42,
        kind: kind,
        content: "@everyone @here <@123> <@&456> 🌍",
        inserted_at: ~U[2026-10-11 12:00:00.000000Z],
        generation: 0
      }

      payload = AsyncWorlds.Workers.DeliverDiscord.payload(delivery)

      # send_private delegates the message send to send_public; both convert
      # the adapter-neutral payload before Message.create normalizes options.
      options = NostrumAdapter.message_options(payload)
      assert options.allowed_mentions == :none
      normalized = Nostrum.Api.Helpers.prepare_allowed_mentions(options)
      assert normalized == payload
      assert normalized.allowed_mentions == %{parse: []}
      assert normalized.content == delivery.content
      assert normalized.nonce == payload.nonce
      assert normalized.enforce_nonce

      # Conversion is safe even if an upstream caller already used :none.
      assert NostrumAdapter.message_options(options) == options
    end
  end

  test "outbound responses classify rejection versus ambiguous delivery without retaining error bodies" do
    error = fn code ->
      {:error, %Nostrum.Error.ApiError{status_code: code, response: "private-token"}}
    end

    assert NostrumAdapter.classify_send(error.(429), :message) ==
             {:error, {:retryable, :rate_limited}}

    assert NostrumAdapter.classify_send({:error, {:retry_after, 1000}}, :message) ==
             {:error, {:retryable, :rate_limited}}

    assert NostrumAdapter.classify_send(error.(403), :message) ==
             {:error, {:permanent, :forbidden}}

    assert NostrumAdapter.classify_send(error.(401), :message) ==
             {:error, {:permanent, :unauthorized}}

    assert NostrumAdapter.classify_send(error.(404), :message) ==
             {:error, {:permanent, :not_found}}

    assert NostrumAdapter.classify_send(error.(400), :message) ==
             {:error, {:permanent, :invalid_request}}

    assert NostrumAdapter.classify_send(error.(500), :message) ==
             {:error, {:ambiguous, :unknown_result}}

    assert NostrumAdapter.classify_send({:error, :timeout}, :message) ==
             {:error, {:ambiguous, :unknown_result}}

    # A DM-channel creation failure cannot have sent the private message yet.
    assert NostrumAdapter.classify_send(error.(500), :channel) ==
             {:error, {:retryable, :channel_unavailable}}

    assert NostrumAdapter.classify_send({:ok, %{id: 123, channel_id: 789}}, :message) ==
             {:ok, %{message_id: "123", channel_id: "789"}}
  end

  test "Nostrum transport URLs and metadata are redacted before logging" do
    secret = "private-webhook-token"

    event = %{
      level: :warning,
      msg: {:string, "/webhooks/111/#{secret}"},
      meta: %{mfa: {Nostrum.Api.Ratelimiter, :connected, 3}, token: secret}
    }

    filtered = LogFilter.filter(event, nil)
    refute inspect(filtered) =~ secret
    assert filtered.level == :warning
    assert LogFilter.filter(%{meta: %{mfa: {__MODULE__, :other, 0}}}, nil) == :ignore

    log =
      capture_log(fn ->
        Logger.bare_log(:warning, "/webhooks/111/#{secret}",
          mfa: {Nostrum.Api.Ratelimiter, :connected, 3}
        )
      end)

    assert log =~ "details redacted"
    refute log =~ secret
  end
end
