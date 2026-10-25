defmodule AsyncWorlds.Discord.DebugInteractions do
  @moduledoc "DM-only private persona controls and interaction discovery."
  alias AsyncWorlds.{Characters, Campaigns}
  alias AsyncWorlds.Discord.{DebugSessions, Help}

  def definition do
    %{
      name: "debug",
      description: "Test player interactions as the DM",
      type: 1,
      options: [
        %{name: "status", description: "Show modes, commands and character picker", type: 1},
        %{
          name: "player",
          description: "Act as a campaign character (real changes)",
          type: 1,
          options: [
            %{
              name: "character",
              description: "Internal character ID from /characters",
              type: 3,
              required: true
            }
          ]
        },
        %{name: "dm", description: "Return to DM role", type: 1},
        %{name: "off", description: "Disable testing and linked-player message copies", type: 1},
        %{
          name: "messages",
          description: "Copy linked players' personal messages to the DM",
          type: 1,
          options: [
            %{
              name: "enabled",
              description: "Enable copies for future tick closes",
              type: 5,
              required: true
            }
          ]
        }
      ]
    }
  end

  def route(%{options: [%{type: 1, name: name} = sub]}) when name in ["status", "dm", "off"] do
    if Map.get(sub, :options) in [nil, []],
      do:
        {:ok,
         {:debug,
          if(name == "status", do: {:status, 0}, else: if(name == "dm", do: :dm, else: :off))},
         :debug},
      else: {:error, :unknown_command}
  end

  def route(%{
        options: [%{type: 1, name: "player", options: [%{type: 3, name: "character", value: id}]}]
      })
      when is_binary(id),
      do: {:ok, {:debug, {:player, id}}, :debug}

  def route(%{
        options: [
          %{type: 1, name: "messages", options: [%{type: 5, name: "enabled", value: enabled}]}
        ]
      })
      when is_boolean(enabled),
      do: {:ok, {:debug, {:messages, enabled}}, :debug}

  def route(_), do: {:error, :unknown_command}

  def component_route(%{component_type: 2, custom_id: id})
      when is_binary(id) and byte_size(id) <= 100 do
    case String.split(id, ":") do
      ["db", "p", character] ->
        {:ok, {:debug, {:player, character}}, :debug}

      ["db", "v", page] ->
        case Integer.parse(page) do
          {page, ""} when page >= 0 -> {:ok, {:debug, {:status, page}}, :debug}
          _ -> {:error, :unknown_command}
        end

      _ ->
        {:error, :unknown_command}
    end
  end

  def component_route(_), do: {:error, :unknown_command}

  def execute({:debug, {:status, page}}, context), do: status(context, page)

  def execute({:debug, operation}, context) do
    with {:ok, _} <-
           DebugSessions.transition(context.campaign.discord_guild_id, context.user_id, operation) do
      status(context, 0)
    end
  end

  defp status(context, page) do
    with {:ok, campaign} <-
           Campaigns.authorize_dm(context.campaign.discord_guild_id, context.user_id),
         {:ok, characters} <- Characters.list_characters(campaign, context.user_id) do
      session = DebugSessions.current(campaign)
      selected = session && Enum.find(characters, &(&1.id == session.character_id))
      mode = if session && session.enabled, do: Atom.to_string(session.role), else: "off"
      copies = session && session.copy_messages == true
      count = max(1, div(length(characters) + 14, 15))
      page = min(page, count - 1)

      buttons =
        characters
        |> Enum.slice(page * 15, 15)
        |> Enum.map(fn c ->
          button("db:p:#{c.id}", String.slice("#{c.id} · #{c.name}", 0, 80))
        end)

      navigation =
        [{page - 1, "Previous"}, {page + 1, "Next"}]
        |> Enum.filter(fn {p, _} -> p >= 0 and p < count end)
        |> Enum.map(fn {p, label} -> button("db:v:#{p}", label) end)

      catalogue = Help.render(context)

      {:ok,
       %{
         content:
           "## Debug mode: #{mode}\n**Character:** #{if selected, do: selected.name, else: "none"}\n**Linked-player message copies:** #{if copies, do: "on", else: "off"} (future tick closes)\n**Changes are real.** `/debug dm` returns to DM; `/debug off` disables testing.\n\n#{catalogue}\n\nSelect a player character · Page #{page + 1}/#{count}",
         components:
           Enum.map(Enum.chunk_every(buttons, 5), &row/1) ++
             if(navigation == [], do: [], else: [row(navigation)])
       }}
    end
  end

  defp button(id, label), do: %{type: 2, style: 2, custom_id: id, label: label}
  defp row(buttons), do: %{type: 1, components: buttons}
end
