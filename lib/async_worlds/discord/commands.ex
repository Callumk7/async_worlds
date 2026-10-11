defmodule AsyncWorlds.Discord.Commands do
  @moduledoc """
  World-only commands using the shared lifecycle APIs. The dispatcher authorizes
  the configured campaign DM before invoking admin operations. Replies are always
  private; public announcements belong exclusively to the durable domain outbox.
  """

  alias AsyncWorlds.{Clocks, Ticks}

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

  def execute(:clocks, %{campaign: campaign}) do
    lines =
      campaign.id
      |> Clocks.list_clocks()
      |> Enum.reject(&(&1.visibility == :hidden))
      |> Enum.map(fn clock ->
        if clock.visibility == :known,
          do: clock.name,
          else: "#{clock.name}: #{clock.filled}/#{clock.segments}"
      end)

    {:ok, if(lines == [], do: "No visible clocks yet.", else: Enum.join(lines, "\n"))}
  end

  def execute(:admin, _context) do
    {:ok, "DM console: #{admin_url()}\nSign in with your configured DM Discord account."}
  end

  def execute(:tick_open, %{campaign: campaign}) do
    case Ticks.open_tick(campaign.id) do
      {:ok, tick} ->
        {:ok, "Tick #{tick.number} is open. Its public announcement is queued."}

      {:error, :active_tick} ->
        {:ok, "A tick is already active. Use /tick status before retrying."}

      error ->
        error
    end
  end

  def execute(:tick_close, %{campaign: campaign}) do
    case Ticks.active_tick(campaign.id) do
      nil ->
        {:ok, "No active tick to close."}

      tick ->
        with {:ok, %{tick: closed}} <- Ticks.close_tick(campaign.id, tick.id) do
          {:ok,
           "Tick #{closed.number}: #{status(closed.status)}\nClosing creates a private draft; nothing is published automatically. Review in #{admin_url()}"}
        end
    end
  end

  def execute(:tick_status, %{campaign: campaign}) do
    tick = Ticks.active_tick(campaign.id) || Ticks.latest_published_tick(campaign.id)

    content =
      if tick,
        do: "Tick #{tick.number}: #{status(tick.status)}",
        else: "No ticks yet. Ready to open the first world tick."

    {:ok, content <> "\nWorld-only status; character submissions are not tracked yet."}
  end

  defp status(:open), do: "open — ready to close and resolve the world."
  defp status(:resolving), do: "resolving — private draft pending."
  defp status(:in_review), do: "in review — private draft ready for DM review/publication."
  defp status(:published), do: "published — ready to open the next world tick."

  defp admin_url, do: AsyncWorldsWeb.Endpoint.url() <> "/dashboard"
end
