defmodule AsyncWorlds.Discord.ModalDeadline do
  @moduledoc "Bound all pre-modal preparation, including pool/lock waits, before attempting an acknowledgment."

  def deadline, do: System.monotonic_time(:millisecond) + 1500

  # Only read-only modal preparation belongs here. Transport stays in the caller;
  # an expired task can never race a callback or a journal insert.
  def run(deadline, fun) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :modal_deadline}
    else
      task =
        Task.Supervisor.async_nolink(AsyncWorlds.Discord.ModalTasks, fn ->
          AsyncWorlds.Discord.Dispatcher.safely(:modal_preparation, fun)
        end)

      case Task.yield(task, remaining) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} ->
          if System.monotonic_time(:millisecond) < deadline,
            do: result,
            else: {:error, :modal_deadline}

        _ ->
          {:error, :modal_deadline}
      end
    end
  end
end
