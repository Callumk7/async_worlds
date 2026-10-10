defmodule AsyncWorlds.Workers.ResolveTick do
  @moduledoc "Durable, retry-safe resolution of a frozen tick; never overwrites a reviewed draft."
  use Oban.Worker, queue: :resolution, max_attempts: 10
  alias AsyncWorlds.Ticks
  alias AsyncWorlds.Ticks.WorldResolver
  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"campaign_id" => campaign, "tick_id" => tick, "input_revision" => revision}
      }) do
    with {:ok, snapshot} <- Ticks.fetch_snapshot(campaign, tick),
         true <- snapshot.revision == revision,
         {:ok, current} <- Ticks.fetch_tick(campaign, tick) do
      case current.status do
        status when status in [:in_review, :published] -> :ok
        :resolving -> resolve(campaign, tick, snapshot)
        _ -> {:cancel, :invalid_transition}
      end
    else
      false -> {:cancel, :stale_input}
      {:error, reason} when reason in [:not_found, :not_closed] -> {:cancel, reason}
    end
  rescue
    _ ->
      Logger.warning("Tick resolution failed", discord_stage: :resolution)
      {:error, :resolution_failed}
  end

  def perform(_), do: {:cancel, :invalid_job}

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(1)

  defp resolve(campaign, tick, snapshot) do
    with {:ok, payload} <- WorldResolver.resolve(snapshot),
         {:ok, _} <- Ticks.put_draft(campaign, tick, snapshot.revision, payload) do
      :ok
    else
      {:error, :invalid_snapshot} ->
        {:cancel, :invalid_snapshot}

      {:error, :stale_draft} ->
        :ok

      {:error, {:invalid_transition, status, :put_draft}}
      when status in [:in_review, :published] ->
        :ok

      {:error, _} ->
        {:error, :resolution_failed}
    end
  end
end
