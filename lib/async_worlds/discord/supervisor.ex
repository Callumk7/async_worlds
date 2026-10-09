defmodule AsyncWorlds.Discord.Supervisor do
  @moduledoc "Owns the optional Nostrum gateway, bounded event workers and consumer."
  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Supervisor.init(
      [
        Nostrum.Application,
        {Task.Supervisor, name: AsyncWorlds.Discord.Tasks, max_children: 100},
        {AsyncWorlds.Discord.Consumer, name: AsyncWorlds.Discord.Consumer}
      ],
      strategy: :rest_for_one
    )
  end
end
