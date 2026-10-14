defmodule AsyncWorlds.Discord.Help do
  @moduledoc "Read-only discovery from the command catalogue used for registration and routing."

  alias AsyncWorlds.Campaigns
  alias AsyncWorlds.Discord.Commands

  @doc "Render the current actor's available commands, including real-DM debug controls."
  def render(context, catalogue \\ Commands.catalogue()) do
    entries = Enum.flat_map(catalogue, &entries(&1, [], nil))

    [
      section(entries, :player, "Player commands"),
      if(context.role == :dm, do: section(entries, :dm, "DM commands")),
      if(Campaigns.dm?(context.campaign, context.user_id),
        do: section(entries, :debug, "Debug controls (real DM)")
      )
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp entries(entry, path, inherited_permission) do
    path = path ++ [entry.name]
    permission = Map.get(entry, :permission, inherited_permission)
    options = Map.get(entry, :options, [])
    subcommands = Enum.filter(options, &(&1.type in [1, 2]))

    if subcommands == [] do
      arguments =
        Enum.map(options, fn option ->
          if Map.get(option, :required, false),
            do: "#{option.name}:<#{option.name}>",
            else: "[#{option.name}]"
        end)

      [
        %{
          usage: "/" <> Enum.join(path ++ arguments, " "),
          description: entry.description,
          permission: permission
        }
      ]
    else
      Enum.flat_map(subcommands, &entries(&1, path, permission))
    end
  end

  defp section(entries, permission, title) do
    case Enum.filter(entries, fn entry ->
           entry.permission == permission or
             (permission == :player and entry.permission == :member)
         end) do
      [] ->
        nil

      available ->
        title <>
          "\n" <>
          Enum.map_join(available, "\n", &"#{&1.usage} — #{&1.description}")
    end
  end
end
