defmodule AsyncWorlds.Discord.LocationCommands do
  @moduledoc "Read-only campaign location commands for verified guild members, independent of characters."
  alias AsyncWorlds.Locations

  def definition do
    %{
      name: "location",
      description: "Browse the campaign's locations",
      type: 1,
      permission: :member,
      options: [
        %{name: "list", description: "List campaign locations and their IDs", type: 1},
        %{
          name: "show",
          description: "Show a campaign location's name and description",
          type: 1,
          options: [
            %{
              name: "location",
              description: "Location ID from /location list",
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
      do: {:ok, :location_list, :member},
      else: {:error, :unknown_command}
  end

  def route(%{
        options: [
          %{type: 1, name: "show", options: [%{type: 3, name: "location", value: id}]}
        ]
      })
      when is_binary(id) and byte_size(id) in 1..19,
      do: {:ok, {:location_show, id}, :member}

  def route(_), do: {:error, :unknown_command}

  def execute(:location_list, %{campaign: campaign}) do
    with {:ok, locations} <- Locations.list_campaign_locations(campaign.discord_guild_id) do
      content =
        if locations == [],
          do: "No locations yet in this campaign.",
          else:
            "Campaign locations\n" <>
              Enum.map_join(locations, "\n", &"#{&1.id} · #{&1.name}") <>
              "\nUse /location show location:<id> to read a location's description."

      {:ok, content}
    end
  end

  def execute({:location_show, id}, %{campaign: campaign}) do
    case Locations.get_campaign_location(campaign.discord_guild_id, id) do
      {:ok, location} ->
        {:ok,
         "#{location.name} (ID #{location.id})\n" <>
           (location.description || "No description yet.")}

      {:error, :not_found} ->
        {:ok, "Location not found in this campaign. Use /location list to find its ID."}

      error ->
        error
    end
  end
end
