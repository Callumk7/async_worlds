defmodule AsyncWorlds.Discord.Commands do
  @moduledoc """
  World-tick and character commands using shared domain APIs. The dispatcher authorizes
  the configured campaign DM before invoking admin operations. Replies are always
  private; public announcements belong exclusively to the durable domain outbox.
  """

  alias AsyncWorlds.{Characters, Clocks}
  alias AsyncWorlds.DM.Ticks

  alias AsyncWorlds.Discord.{
    DebugInteractions,
    FactionCommands,
    JournalInteractions,
    LocationCommands,
    QuestInteractions
  }

  @doc "Discord registration definitions, stripped of internal routing metadata."
  def definitions, do: Enum.map(catalogue(), &discord_definition/1)

  @doc """
  Single source for registration, routing permissions and command discovery.

  Entries use Discord's definition format plus internal `:permission` and `:command`
  metadata. Subcommands inherit their parent's permission unless overridden;
  actionable entries name the operation passed to `execute/2`. Discord registration
  strips this metadata, and help reads the same entries at request time. No separate
  help descriptions or command list should be maintained.
  """
  def catalogue do
    [
      Map.put(DebugInteractions.definition(), :permission, :debug),
      JournalInteractions.definition(),
      AsyncWorlds.Discord.ChronicleCommands.definition(),
      AsyncWorlds.Discord.IntentCommands.definition(),
      FactionCommands.definition(),
      LocationCommands.definition(),
      %{
        name: "clocks",
        description: "View the campaign's visible clocks",
        type: 1,
        permission: :player,
        command: :clocks
      },
      %{
        name: "tick",
        description: "Manage the campaign tick (DM only)",
        type: 1,
        permission: :dm,
        options: [
          %{name: "open", description: "Open a new tick", type: 1, command: :tick_open},
          %{
            name: "close",
            description: "Close submissions and resolve the tick",
            type: 1,
            command: :tick_close
          },
          %{
            name: "status",
            description: "View the current tick status",
            type: 1,
            command: :tick_status
          },
          %{
            name: "remind",
            description: "Privately remind players with missing submissions",
            type: 1,
            command: :tick_remind
          }
        ]
      },
      %{
        name: "admin",
        description: "Access the campaign web admin (DM only)",
        type: 1,
        permission: :dm,
        command: :admin
      },
      %{
        name: "character",
        description: "View your character and visible flags",
        type: 1,
        permission: :player,
        command: :character
      },
      %{
        name: "quest",
        description: "View your private quest and choose an action",
        type: 1,
        permission: :player,
        command: :quest
      },
      %{
        name: "result",
        description: "Retrieve your latest approved personal result",
        type: 1,
        permission: :player,
        command: :result
      },
      %{
        name: "submission",
        description: "View, revise or clear your latest quest choice",
        type: 1,
        permission: :player,
        command: :submission
      },
      %{
        name: "help",
        description: "List the commands available to you",
        type: 1,
        permission: :player,
        command: :help
      }
    ]
  end

  def route(%{name: name} = data) do
    case Enum.find(catalogue(), &(&1.name == name)) do
      %{name: "chronicle"} ->
        AsyncWorlds.Discord.ChronicleCommands.route(data)

      %{name: "intent"} ->
        AsyncWorlds.Discord.IntentCommands.route(data)

      %{name: "location"} ->
        LocationCommands.route(data)

      %{name: "faction"} ->
        FactionCommands.route(data)

      %{name: "journal"} ->
        JournalInteractions.route(data)

      %{name: "debug", permission: permission} ->
        with {:ok, command, _} <- DebugInteractions.route(data),
             do: {:ok, command, permission}

      %{permission: permission} = entry ->
        route_entry(entry, data, permission)

      _ ->
        {:error, :unknown_command}
    end
  end

  def route(_), do: {:error, :unknown_command}

  defp route_entry(entry, data, inherited_permission) do
    permission = Map.get(entry, :permission, inherited_permission)

    case {Map.get(entry, :command), Map.get(data, :options)} do
      {command, options} when not is_nil(command) and options in [nil, []] ->
        {:ok, command, permission}

      {nil, [%{type: type, name: name} = option]} when type in [1, 2] ->
        case Enum.find(Map.get(entry, :options, []), &(&1.name == name and &1.type == type)) do
          nil -> {:error, :unknown_command}
          child -> route_entry(child, option, permission)
        end

      _ ->
        {:error, :unknown_command}
    end
  end

  defp discord_definition(entry) do
    definition = Map.drop(entry, [:command, :permission])

    case Map.fetch(definition, :options) do
      {:ok, options} -> Map.put(definition, :options, Enum.map(options, &discord_definition/1))
      :error -> definition
    end
  end

  def execute({:chronicle, _, _} = command, context),
    do: AsyncWorlds.Discord.ChronicleCommands.execute(command, context)

  def execute({:intent, _, _} = command, context),
    do: AsyncWorlds.Discord.IntentCommands.execute(command, context)

  def execute({:debug, _} = command, context), do: DebugInteractions.execute(command, context)

  def execute(command, context)
      when is_tuple(command) and
             elem(command, 0) in [
               :journal_new,
               :journal_submit,
               :journal_list,
               :journal_open,
               :journal_delete,
               :journal_control
             ],
      do: JournalInteractions.execute(command, context)

  def execute(:location_list, context), do: LocationCommands.execute(:location_list, context)

  def execute({:location_show, _} = command, context),
    do: LocationCommands.execute(command, context)

  def execute(:faction_list, context), do: FactionCommands.execute(:faction_list, context)

  def execute({:faction_show, _} = command, context),
    do: FactionCommands.execute(command, context)

  def execute(:help, context), do: {:ok, AsyncWorlds.Discord.Help.render(context)}

  def execute(:quest, context), do: QuestInteractions.show(context)

  def execute(:result, %{campaign: campaign} = context),
    do: AsyncWorlds.Discord.PrivateRetrieval.result(campaign.discord_guild_id, access(context))

  def execute(:submission, %{campaign: campaign} = context) do
    case AsyncWorlds.Quests.Submissions.player_state(campaign.discord_guild_id, access(context)) do
      {:ok, _} ->
        QuestInteractions.show(context)

      {:error, reason} when reason in [:no_tick, :no_quest] ->
        case AsyncWorlds.Discord.PrivateRetrieval.submission(
               campaign.discord_guild_id,
               access(context)
             ) do
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

  def execute(:character, %{campaign: campaign} = context) do
    with {:ok, payload} <-
           Characters.player_character(
             campaign.discord_guild_id,
             Map.get(context, :access, context.user_id)
           ) do
      facts =
        payload.flags
        |> Enum.sort()
        |> Enum.map(fn {key, flag} -> "#{key}: #{to_string(flag["value"])}" end)

      {:ok, Enum.join([payload.name | facts], "\n")}
    end
  end

  def execute(:admin, _context) do
    {:ok, "DM console: #{admin_url()}\nSign in with your configured DM Discord account."}
  end

  def execute(:tick_open, context) do
    case Ticks.open_tick(dm_scope(context)) do
      {:ok, tick} ->
        {:ok, "Tick #{tick.number} is open. Its public announcement is queued."}

      {:error, :active_tick} ->
        {:ok, "A tick is already active. Use /tick status before retrying."}

      error ->
        error
    end
  end

  def execute(:tick_close, context) do
    case Ticks.close_active_tick(dm_scope(context)) do
      {:error, :no_tick} ->
        {:ok, "No active tick to close."}

      {:ok, %{tick: closed}} ->
        {:ok,
         "Tick #{closed.number}: #{status(closed.status)}\nClosing queues a private draft; nothing is published automatically. Quest choices resolve privately from frozen inputs; management stays locked until publication. Review in #{admin_url()}"}

      error ->
        error
    end
  end

  def execute(:tick_remind, %{interaction_id: request} = context) do
    with {:ok, count} <- Ticks.remind(dm_scope(context), request) do
      {:ok,
       "Private reminder intents recorded for #{count} missing submissions. Repeated requests do not resend. Inspect failures and use targeted retries in the DM console; ambiguous sends require confirmation."}
    end
  end

  def execute(:tick_status, %{campaign: campaign, user_id: user_id} = context) do
    with {:ok, tick} <- Ticks.status(dm_scope(context)) do
      tick_status_content(campaign, user_id, tick)
    end
  end

  defp tick_status_content(campaign, user_id, tick) do
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

  defp dm_scope(context),
    do: %{campaign: context.campaign, discord_user_id: context.user_id}

  defp access(context), do: Map.get(context, :access, context.user_id)

  defp admin_url, do: AsyncWorldsWeb.Endpoint.url() <> "/dashboard"
end
