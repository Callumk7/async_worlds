defmodule AsyncWorlds.Workers.DeliverDiscord do
  @moduledoc "Conservative outbound delivery: persisted claims, no blind retry of unknown sends."
  use Oban.Worker, queue: :discord_delivery, max_attempts: 10
  alias AsyncWorlds.Deliveries
  alias AsyncWorlds.Deliveries.Delivery
  alias AsyncWorlds.Discord.Snowflake
  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"delivery_id" => id, "generation" => generation}}) do
    opts = Application.fetch_env!(:async_worlds, :discord)

    if Keyword.get(opts, :enabled, false) do
      case Deliveries.claim(id, generation) do
        {:ok, :skip} -> :ok
        {:ok, %Delivery{} = claim} -> deliver(claim, Keyword.fetch!(opts, :adapter))
        {:error, :not_found} -> {:cancel, :not_found}
      end
    else
      # Paused while offline; no claim or external send has happened.
      {:snooze, 60}
    end
  rescue
    _ ->
      Logger.warning("Discord delivery job failed", discord_stage: :delivery)
      {:error, :delivery_failed}
  end

  def perform(_), do: {:cancel, :invalid_job}

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(2)

  @impl Oban.Worker
  def backoff(_job), do: 60

  @doc false
  def payload(delivery) do
    # Discord deduplicates this nonce only for a few minutes, not indefinitely.
    # It also limits duplicate sends from Nostrum's internal transport requeues.
    nonce =
      :crypto.hash(:sha256, "#{delivery.id}:#{delivery.inserted_at}:#{delivery.generation}")
      |> Base.encode16(case: :lower)
      |> binary_part(0, 24)

    %{
      content: delivery.content,
      allowed_mentions: %{parse: []},
      nonce: nonce,
      enforce_nonce: true
    }
  end

  defp deliver(claim, adapter) do
    result = send_safely(claim, adapter)

    case Deliveries.settle(claim, result) do
      {:ok, _} ->
        case result do
          {:ok, _} -> :ok
          {:error, {:retryable, reason}} -> {:error, reason}
          {:error, {_, reason}} -> {:cancel, reason}
        end

      {:error, :stale_attempt} ->
        :ok

      _ ->
        {:error, :delivery_failed}
    end
  end

  defp send_safely(claim, adapter) do
    result =
      case claim.kind do
        :public -> adapter.send_public(claim.recipient_id, payload(claim))
        :private -> adapter.send_private(claim.recipient_id, payload(claim))
      end

    normalize(result)
  rescue
    _ -> {:error, {:ambiguous, :unknown_result}}
  catch
    _, _ -> {:error, {:ambiguous, :unknown_result}}
  end

  defp normalize({:ok, %{message_id: message, channel_id: channel}}) do
    with {:ok, message} <- Snowflake.cast(message), {:ok, channel} <- Snowflake.cast(channel) do
      {:ok, %{message_id: message, channel_id: channel}}
    else
      _ -> {:error, {:ambiguous, :unknown_result}}
    end
  end

  defp normalize({:error, {:retryable, reason}})
       when reason in [:rate_limited, :channel_unavailable],
       do: {:error, {:retryable, reason}}

  defp normalize({:error, {:permanent, reason}})
       when reason in [:forbidden, :unauthorized, :not_found, :invalid_request],
       do: {:error, {:permanent, reason}}

  defp normalize({:error, {:ambiguous, :unknown_result}}),
    do: {:error, {:ambiguous, :unknown_result}}

  defp normalize(_), do: {:error, {:ambiguous, :unknown_result}}
end
