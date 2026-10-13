defmodule AsyncWorlds.Discord.Consumer do
  @moduledoc "Supervised gateway consumer; only interaction events enter the application boundary."
  use Nostrum.Consumer

  alias AsyncWorlds.Discord.Dispatcher

  @impl true
  def handle_event({:INTERACTION_CREATE, interaction, _state}), do: Dispatcher.handle(interaction)

  # Override Nostrum's unlinked Task and exception-inspecting logger. Workers are
  # supervised and failures cannot dump token-bearing event payloads to logs.
  @impl GenServer
  def handle_info({:event, event}, state) do
    deadline = AsyncWorlds.Discord.ModalDeadline.deadline()

    Dispatcher.safely(:consumer, fn ->
      Task.Supervisor.start_child(AsyncWorlds.Discord.Tasks, fn ->
        Dispatcher.safely(:consumer, fn ->
          case event do
            {:INTERACTION_CREATE, interaction, _} ->
              opts = Application.fetch_env!(:async_worlds, :discord)
              Dispatcher.handle(interaction, Keyword.put(opts, :modal_deadline, deadline))

            _ ->
              handle_event(event)
          end
        end)
      end)
    end)

    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}
end
