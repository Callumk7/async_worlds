defmodule AsyncWorlds.Discord.Commands do
  @moduledoc """
  Milestone-1 slash-command definitions and routing. Command behavior ships in
  ENG-10; these placeholders never change campaign state.

  Future handlers receive the authorized campaign, verified user and interaction
  ID. They must call shared domain operations and enforce transitions/idempotency
  in database transactions, not rely on Discord acknowledgments for correctness.
  """

  def definitions do
    [
      %{name: "clocks", description: "View the campaign's visible clocks", type: 1},
      %{
        name: "tick",
        description: "Manage the campaign tick (DM only)",
        type: 1,
        options: [
          %{name: "open", description: "Open a new tick", type: 1},
          %{name: "close", description: "Close submissions and resolve the tick", type: 1},
          %{name: "status", description: "View the current tick status", type: 1}
        ]
      },
      %{name: "admin", description: "Access the campaign web admin (DM only)", type: 1}
    ]
  end

  def route(%{name: name} = data) when name in ["clocks", "admin"] do
    if Map.get(data, :options) in [nil, []] do
      case name do
        "clocks" -> {:ok, :clocks, :player}
        "admin" -> {:ok, :admin, :dm}
      end
    else
      {:error, :unknown_command}
    end
  end

  def route(%{name: "tick", options: [%{type: 1, name: name} = option]}) do
    if Map.get(option, :options) in [nil, []] do
      case name do
        "open" -> {:ok, :tick_open, :dm}
        "close" -> {:ok, :tick_close, :dm}
        "status" -> {:ok, :tick_status, :dm}
        _ -> {:error, :unknown_command}
      end
    else
      {:error, :unknown_command}
    end
  end

  def route(_), do: {:error, :unknown_command}

  def execute(_command, _context),
    do: {:ok, "This command is registered, but its campaign behavior is not implemented yet."}
end
