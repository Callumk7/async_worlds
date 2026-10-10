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
