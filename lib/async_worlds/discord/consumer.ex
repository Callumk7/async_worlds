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
    Dispatcher.safely(:consumer, fn ->
      Task.Supervisor.start_child(AsyncWorlds.Discord.Tasks, fn ->
        Dispatcher.safely(:consumer, fn -> handle_event(event) end)
      end)
    end)

    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}
end
