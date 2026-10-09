defmodule AsyncWorlds.Discord.FakeAdapter do
  @moduledoc false
  use GenServer
  @behaviour AsyncWorlds.Discord.Adapter

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def fail(stage, value), do: GenServer.call(__MODULE__, {:fail, stage, value})
  def commands, do: GenServer.call(__MODULE__, :commands)

  @impl true
  def defer(envelope), do: call(:defer, envelope)

  @impl true
  def edit_response(envelope, content), do: call(:edit_response, {envelope, content})

  @impl true
  def register_commands(app, guild, commands),
    do: call(:register_commands, {app, guild, commands})

  defp call(stage, args) do
    case GenServer.call(__MODULE__, {stage, args}) do
      {:raise, message} -> raise message
      result -> result
    end
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       owner: Keyword.fetch!(opts, :owner),
       acknowledged: MapSet.new(),
       commands: %{},
       failures: %{}
     }}
  end

  @impl true
  def handle_call({:fail, stage, value}, _from, state) do
    {:reply, :ok, %{state | failures: Map.put(state.failures, stage, value)}}
  end

  def handle_call(:commands, _from, state), do: {:reply, state.commands, state}

  def handle_call({stage, args}, _from, state) do
    send(state.owner, {:discord, stage, args})

    case Map.get(state.failures, stage) do
      nil -> perform(stage, args, state)
      result -> {:reply, result, state}
    end
  end

  defp perform(:defer, envelope, state) do
    if MapSet.member?(state.acknowledged, envelope.id) do
      {:reply, {:error, :already_acknowledged}, state}
    else
      {:reply, :ok, %{state | acknowledged: MapSet.put(state.acknowledged, envelope.id)}}
    end
  end

  defp perform(:edit_response, _, state), do: {:reply, :ok, state}

  defp perform(:register_commands, {app, guild, commands}, state) do
    {:reply, {:ok, commands},
     %{state | commands: Map.put(state.commands, {app, guild}, commands)}}
  end
end
