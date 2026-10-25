defmodule AsyncWorlds.Discord.FactionCommands do
  @moduledoc "Read-only campaign faction commands for verified guild members, independent of characters."
  alias AsyncWorlds.Factions

  def definition do
    %{
      name: "faction",
      description: "Browse the campaign's factions",
      type: 1,
      permission: :member,
      options: [
        %{name: "list", description: "List campaign factions and their IDs", type: 1},
        %{
          name: "show",
          description: "Show a campaign faction's name and description",
          type: 1,
          options: [
            %{
              name: "faction",
              description: "Faction ID from /faction list",
              type: 3,
              required: true
            }
          ]
        }
      ]
    }
  end

  def route(%{options: [%{type: 1, name: "list"} = option]}) do
    if Map.get(option, :options, []) == [],
      do: {:ok, :faction_list, :member},
      else: {:error, :unknown_command}
  end

  def route(%{
        options: [
          %{type: 1, name: "show", options: [%{type: 3, name: "faction", value: id}]}
        ]
      })
      when is_binary(id) and byte_size(id) in 1..19,
      do: {:ok, {:faction_show, id}, :member}

  def route(_), do: {:error, :unknown_command}

  def execute(:faction_list, %{campaign: campaign}) do
    with {:ok, factions} <- Factions.list_campaign_factions(campaign.discord_guild_id) do
      content =
        if factions == [],
          do: "No factions yet in this campaign.",
          else:
            "## Campaign factions\n" <>
              Enum.map_join(factions, "\n", &"- #{&1.id} · #{&1.name}") <>
              "\n\nUse `/faction show faction:<id>` to read a faction's description."

      {:ok, content}
    end
  end

  def execute({:faction_show, id}, %{campaign: campaign}) do
    case Factions.get_campaign_faction(campaign.discord_guild_id, id) do
      {:ok, faction} ->
        {:ok,
         "## #{faction.name} (ID #{faction.id})\n\n" <>
           (faction.description || "No description yet.")}

      {:error, :not_found} ->
        {:ok, "Faction not found in this campaign. Use /faction list to find its ID."}

      error ->
        error
    end
  end
end
