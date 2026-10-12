defmodule AsyncWorlds.Discord.Commands do
  @moduledoc """
  World-tick and character commands using shared domain APIs. The dispatcher authorizes
  the configured campaign DM before invoking admin operations. Replies are always
  private; public announcements belong exclusively to the durable domain outbox.
  """

  alias AsyncWorlds.{Characters, Clocks, Ticks}
  alias AsyncWorlds.Discord.QuestInteractions

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
          %{name: "status", description: "View the current tick status", type: 1},
          %{
            name: "remind",
            description: "Privately remind players with missing submissions",
            type: 1
          }
        ]
      },
      %{name: "admin", description: "Access the campaign web admin (DM only)", type: 1},
      %{name: "character", description: "View your character and visible flags", type: 1},
      %{name: "quest", description: "View your private quest and choose an action", type: 1},
      %{name: "result", description: "Retrieve your latest approved personal result", type: 1},
      %{
        name: "submission",
        description: "View, revise or clear your latest quest choice",
        type: 1
      }
    ]
  end

  def route(%{name: name} = data)
      when name in ["clocks", "admin", "character", "quest", "submission", "result"] do
    if Map.get(data, :options) in [nil, []] do
      case name do
        "clocks" -> {:ok, :clocks, :player}
        "admin" -> {:ok, :admin, :dm}
        "character" -> {:ok, :character, :player}
        "quest" -> {:ok, :quest, :player}
        "submission" -> {:ok, :submission, :player}
        "result" -> {:ok, :result, :player}
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
        "remind" -> {:ok, :tick_remind, :dm}
        _ -> {:error, :unknown_command}
      end
    else
      {:error, :unknown_command}
    end
  end

  def route(_), do: {:error, :unknown_command}

  def execute(:quest, context), do: QuestInteractions.show(context)

  def execute(:result, %{campaign: campaign, user_id: user}),
    do: AsyncWorlds.Discord.PrivateRetrieval.result(campaign.discord_guild_id, user)

  def execute(:submission, %{campaign: campaign, user_id: user} = context) do
    case AsyncWorlds.Quests.Submissions.player_state(campaign.discord_guild_id, user) do
      {:ok, _} ->
        QuestInteractions.show(context)

      {:error, reason} when reason in [:no_tick, :no_quest] ->
        case AsyncWorlds.Discord.PrivateRetrieval.submission(campaign.discord_guild_id, user) do
          {:ok, :no_submission} -> QuestInteractions.show(context)
          result -> result
        end

      error ->
        error
    end
  end

  def execute({:quest_page, _, _} = command, context),
    do: QuestInteractions.execute(command, context)

  def execute({:quest_component, _, _, _} = command, context),
    do: QuestInteractions.execute(command, context)

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

  def execute(:character, %{campaign: campaign, user_id: verified_user_id}) do
    with {:ok, payload} <-
           Characters.player_character(campaign.discord_guild_id, verified_user_id) do
      facts =
        payload.flags
        |> Enum.sort()
        |> Enum.map(fn {key, flag} -> "#{key}: #{Jason.encode!(flag["value"])}" end)

      {:ok, Enum.join([payload.name | facts], "\n")}
    end
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
           "Tick #{closed.number}: #{status(closed.status)}\nClosing queues a private draft; nothing is published automatically. Quest choices resolve privately from frozen inputs; management stays locked until publication. Review in #{admin_url()}"}
        end
    end
  end

  def execute(:tick_remind, %{campaign: campaign, user_id: user, interaction_id: request}) do
    with {:ok, count} <-
           AsyncWorlds.Ticks.PrivateNotifications.remind(campaign.discord_guild_id, user, request) do
      {:ok,
       "Private reminder intents recorded for #{count} missing submissions. Repeated requests do not resend. Inspect failures and use targeted retries in the DM console; ambiguous sends require confirmation."}
    end
  end

  def execute(:tick_status, %{campaign: campaign, user_id: user_id}) do
    tick = Ticks.active_tick(campaign.id) || Ticks.latest_published_tick(campaign.id)

    content =
      if tick,
        do: "Tick #{tick.number}: #{status(tick.status)}",
        else: "No ticks yet. Ready to open the first world tick."

    readiness =
      if tick do
        case AsyncWorlds.Quests.Submissions.readiness(campaign, user_id, tick.id) do
          {:ok, counts} ->
            "\nQuest choices: #{counts.submitted}/#{counts.active} ready, #{counts.missing} missing. Informational only; no automatic close."

          _ ->
            ""
        end
      else
        ""
      end

    {:ok, content <> readiness}
  end

  defp status(:open), do: "open — ready to close and resolve the world."

  defp status(:resolving),
    do: "resolving — private draft pending; frozen quest choices and world effects are queued."

  defp status(:in_review), do: "in review — private draft ready for DM review/publication."
  defp status(:published), do: "published — ready to open the next world tick."

  defp admin_url, do: AsyncWorldsWeb.Endpoint.url() <> "/dashboard"
end
