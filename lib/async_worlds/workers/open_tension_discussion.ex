defmodule AsyncWorlds.Workers.OpenTensionDiscussion do
  @moduledoc "Creates at most one claimed conversation; an interrupted/unknown create requires explicit recovery."
  use Oban.Worker, queue: :discord_delivery, max_attempts: 10
  alias AsyncWorlds.TensionDiscussions

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"discussion_id" => id}}) do
    opts = Application.fetch_env!(:async_worlds, :discord)

    if Keyword.get(opts, :enabled, false) do
      run(id, Keyword.fetch!(opts, :adapter))
    else
      {:snooze, 60}
    end
  end

  @doc false
  def run(id, adapter) do
    case TensionDiscussions.claim(id) do
      {:ok, {:ready, _}} ->
        dispatch(id)

      {:ok, {:create, d}} ->
        result = create(adapter, d)

        case TensionDiscussions.settle(d, result) do
          {:ok, %{status: "ready"}} -> dispatch(id)
          {:ok, %{status: "pending"}} -> {:error, :retryable}
          _ -> {:cancel, :recovery_required}
        end

      {:ok, :skip} ->
        :ok

      _ ->
        {:error, :claim_failed}
    end
  end

  defp dispatch(id) do
    case TensionDiscussions.dispatch(id) do
      {:ok, :ok} -> :ok
      _ -> {:error, :dispatch_failed}
    end
  end

  defp create(adapter, d) do
    case adapter.create_public_thread(d.parent_id, %{
           name: String.slice(d.name, 0, 100),
           type: 11,
           auto_archive_duration: 10080
         }) do
      {:ok, %{thread_id: id}} ->
        case AsyncWorlds.Discord.Snowflake.cast(id) do
          {:ok, id} -> {:ok, id}
          _ -> {:error, :ambiguous}
        end

      {:error, {:retryable, :rate_limited}} ->
        {:error, :retryable}

      {:error, {:permanent, _}} ->
        {:error, :permanent}

      _ ->
        {:error, :ambiguous}
    end
  rescue
    _ -> {:error, :ambiguous}
  catch
    _, _ -> {:error, :ambiguous}
  end
end
