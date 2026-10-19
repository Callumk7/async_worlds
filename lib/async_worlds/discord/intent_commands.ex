defmodule AsyncWorlds.Discord.IntentCommands do
  @moduledoc "Private slash-command entry and retrieval, independent of outbound delivery."
  alias AsyncWorlds.TensionCommitments

  def definition do
    %{
      name: "intent",
      description: "Private broad intentions (not success or public discussion)",
      type: 1,
      permission: :player,
      options:
        Enum.map(~w(view roster edit confirm withdraw ready), fn action ->
          fields =
            [option("tick", "Tick ID", 4)] ++
              if(action in ~w(view roster),
                do: [],
                else: [
                  option("tension", "Tension ID from view", 4),
                  option("version", "Current version from view; 0 for absent", 4)
                ]
              ) ++
              if(action == "edit",
                do: [
                  option(
                    "intention",
                    "Broad effort, not an established outcome (max 2000 characters)",
                    3
                  ),
                  %{
                    option("approach", "Optional descriptive approach/resources; no spending", 3)
                    | required: false
                  }
                ],
                else: []
              )

          entry = %{name: action, description: description(action), type: 1, options: fields}
          if action == "roster", do: Map.put(entry, :permission, :dm), else: entry
        end)
    }
  end

  defp description("roster"), do: "DM: retrieve private participation, including absent/not-ready"
  defp description("view"), do: "Retrieve your latest private intentions and versions"

  defp description("edit"),
    do: "Save/revise private intent; invalidates confirmation and readiness"

  defp description("confirm"), do: "Explicitly confirm current intent, never success"
  defp description("withdraw"), do: "Withdraw current intent before close"
  defp description("ready"), do: "Signal readiness for current confirmed version; not a quota"

  defp option(name, description, type),
    do: %{name: name, description: description, type: type, required: true}

  def route(%{options: [%{type: 1, name: action, options: options}]})
      when action in ~w(view roster edit confirm withdraw ready) do
    expected = Enum.find(definition().options, &(&1.name == action)).options
    required = for field <- expected, field.required, do: field.name
    names = Enum.map(options, & &1.name)

    valid =
      Enum.all?(required, &(&1 in names)) and length(Enum.uniq(names)) == length(names) and
        Enum.all?(options, fn value ->
          Enum.any?(expected, &(&1.name == value.name and &1.type == value.type)) and
            valid_value?(value)
        end)

    if valid,
      do:
        {:ok, {:intent, action, Map.new(options, &{&1.name, &1.value})},
         if(action == "roster", do: :dm, else: :player)},
      else: {:error, :unknown_command}
  end

  def route(_), do: {:error, :unknown_command}

  defp valid_value?(%{type: 4, name: "version", value: value}),
    do: is_integer(value) and value in 0..2_147_483_646

  defp valid_value?(%{type: 4, value: value}), do: is_integer(value) and value in 1..2_147_483_647
  defp valid_value?(%{type: 3, value: value}), do: is_binary(value)
  defp valid_value?(_), do: false

  def execute({:intent, "roster", args}, context) do
    scope = %{campaign: context.campaign, discord_user_id: context.user_id}
    render_state(TensionCommitments.dm_state(scope, args["tick"]))
  end

  def execute({:intent, "view", args}, context),
    do:
      render_state(
        TensionCommitments.player_state(
          context.campaign.discord_guild_id,
          access(context),
          args["tick"]
        )
      )

  def execute({:intent, action, args}, context) do
    operation =
      case action do
        "edit" -> :edit
        "confirm" -> :confirm
        "withdraw" -> :withdraw
        "ready" -> :ready
      end

    case TensionCommitments.change(
           context.campaign.discord_guild_id,
           access(context),
           args["tick"],
           args["tension"],
           args["version"],
           operation,
           args
         ) do
      {:ok, entry} -> {:ok, header() <> "\n" <> render_entry(entry)}
      error -> explain(error)
    end
  end

  defp access(context), do: Map.get(context, :access, context.user_id)

  defp render_state({:ok, state}) do
    rows =
      Enum.map_join(state.participation, "\n", fn row ->
        "Character #{row.character_id}\n" <> Enum.map_join(row.commitments, "\n", &render_entry/1)
      end)

    {:ok, header() <> "\nTick #{state.tick_id}: #{state.status}\n" <> rows}
  end

  defp render_state(error), do: explain(error)

  defp header,
    do:
      "Private to owner and authorized DM. Intentions are not outcomes. Readiness is informational; missing players do not block close. Discuss freely in Tension threads; use edit then confirm here. No automatic public posting."

  defp render_entry(e),
    do:
      "Tension #{e.tension_id} · version #{e.version} · #{e.state} · #{if e.ready, do: "ready", else: "not ready"}\n#{e.intention || ""}\n#{e.approach || ""}"

  defp explain({:error, :stale_commitment}),
    do:
      {:ok,
       "Nothing changed: stale version. Refresh /intent view before editing, confirming or signalling readiness."}

  defp explain({:error, :tick_closed}),
    do: {:ok, "Nothing changed: tick closed. /intent view retrieves frozen intentions."}

  defp explain({:error, :invalid_commitment}),
    do:
      {:ok,
       "Nothing changed. Edit requires nonblank intention and optional approach, each valid UTF-8 without NUL, at most 2000 characters / 8000 bytes. Confirm before ready."}

  defp explain(error), do: error
end
