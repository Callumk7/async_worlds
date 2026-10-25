defmodule AsyncWorlds.Discord.ChronicleCommands do
  @moduledoc "Private Discord retrieval of the shared published player chronicle, never DM drafts."
  alias AsyncWorlds.Ticks.Chronicle

  def definition do
    %{
      name: "chronicle",
      description: "Explore established campaign Events",
      type: 1,
      permission: :player,
      options: [
        %{
          name: "list",
          description: "Browse Events, optionally filtered",
          type: 1,
          options: [
            %{name: "page", description: "Page number", type: 4, min_value: 1},
            %{name: "tick", description: "Tick ID", type: 3},
            %{
              name: "entity",
              description: "Reference type (pair with entity_id)",
              type: 3,
              choices: Enum.map(~w(tension location character faction), &%{name: &1, value: &1})
            },
            %{name: "entity_id", description: "Referenced entity ID", type: 3},
            %{
              name: "through",
              description: "History boundary from previous page",
              type: 4,
              min_value: 1,
              max_value: 2_147_483_647
            }
          ]
        },
        %{
          name: "show",
          description: "Read an Event and its connections",
          type: 1,
          options: [
            %{name: "tick", description: "Tick ID from list", type: 3, required: true},
            %{name: "event", description: "Event key from list", type: 3, required: true},
            %{name: "entity", description: "Keep reference filter", type: 3},
            %{name: "entity_id", description: "Keep reference ID", type: 3},
            %{name: "scope_tick", description: "Keep tick filter", type: 3},
            %{
              name: "through",
              description: "Keep history boundary",
              type: 4,
              min_value: 1,
              max_value: 2_147_483_647
            }
          ]
        }
      ]
    }
  end

  def route(%{options: [%{type: 1, name: name} = sub]}) when name in ["list", "show"] do
    options = Map.get(sub, :options, [])

    allowed =
      if name == "list",
        do: ~w(page tick entity entity_id through),
        else: ~w(tick event entity entity_id scope_tick through)

    if Enum.all?(options, fn o ->
         Map.get(o, :name) in allowed and
           if(o.name in ~w(page through),
             do: Map.get(o, :type) == 4 and is_integer(Map.get(o, :value)),
             else:
               Map.get(o, :type) == 3 and is_binary(Map.get(o, :value)) and
                 byte_size(o.value) in 1..100
           )
       end) and
         (name == "list" or
            Enum.all?(~w(tick event), fn key -> Enum.any?(options, &(&1.name == key)) end)) and
         length(Enum.uniq_by(options, & &1.name)) == length(options) do
      {:ok,
       {:chronicle, if(name == "list", do: :list, else: :show),
        Map.new(options, &{&1.name, &1.value})}, :player}
    else
      {:error, :unknown_command}
    end
  end

  def route(_), do: {:error, :unknown_command}

  def execute({:chronicle, :list, filters}, c) do
    case Chronicle.list(
           c.campaign.discord_guild_id,
           Map.get(c, :access, c.user_id),
           :player,
           filters
         ) do
      {:ok, page} ->
        filters =
          if page.through > 0, do: Map.put(filters, "through", page.through), else: filters

        show_filters =
          filters
          |> Map.drop(~w(page tick))
          |> then(fn f ->
            if filters["tick"], do: Map.put(f, "scope_tick", filters["tick"]), else: f
          end)

        lines =
          Enum.map_join(
            page.items,
            "\n",
            &"- Tick #{&1["tick_number"]} · #{&1["title"]}\n  `/chronicle show tick:#{&1["tick_id"]} event:#{&1["key"]}#{suffix(show_filters)}`"
          )

        {:ok,
         "## Campaign chronicle · page #{page.page}\n" <>
           if(lines == "", do: "No published Events on this page.", else: lines) <>
           if(page.more?,
             do: "\nMore: `/chronicle list#{suffix(Map.put(filters, "page", page.page + 1))}`",
             else: ""
           ) <>
           if(page.page > 1,
             do:
               "\nPrevious: `/chronicle list#{suffix(Map.put(filters, "page", page.page - 1))}`",
             else: ""
           )}

      error ->
        error
    end
  end

  def execute({:chronicle, :show, p}, c) do
    filters = Map.take(p, ~w(entity entity_id through))
    filters = if p["scope_tick"], do: Map.put(filters, "tick", p["scope_tick"]), else: filters

    with {:ok, detail} <-
           Chronicle.fetch(
             c.campaign.discord_guild_id,
             Map.get(c, :access, c.user_id),
             :player,
             p["tick"],
             p["event"],
             filters
           ) do
      e = detail.event

      refs =
        Enum.map_join(
          e["references"],
          "\n",
          &"#{&1["entity"]}: #{&1["name"]} · /chronicle list entity:#{&1["entity"]} entity_id:#{&1["id"]}"
        )

      follow =
        Enum.map_join(
          e["follow_on"],
          "\n",
          &"Led to: #{&1["name"]} · /chronicle list entity:tension entity_id:#{&1["id"]}"
        )

      nav =
        for {label, target} <- [{"Earlier", detail.earlier}, {"Later", detail.later}],
            target,
            do:
              "#{label}: #{target["title"]} · /chronicle show tick:#{target["tick_id"]} event:#{target["key"]}#{suffix(Map.take(p, ~w(entity entity_id scope_tick through)))}"

      changes =
        Enum.map_join(e["changes"] || [], "\n", fn ch ->
          before = ch["before"] || %{}
          after_record = ch["after"]

          if ch["entity"] == "clock",
            do:
              "#{after_record["name"]}: #{before["filled"] || 0} → #{AsyncWorlds.Discord.ClockProgress.render(after_record["filled"], after_record["segments"])}",
            else:
              "#{after_record["name"]}: #{before["status"] || "new"} → #{after_record["status"]}"
        end)

      {:ok,
       Enum.reject(
         ["## Tick #{e["tick_number"]} · #{e["title"]}", e["text"], refs, follow, changes | nav],
         &(&1 == "")
       )
       |> Enum.join("\n\n")}
    end
  end

  defp suffix(filters),
    do: filters |> Enum.sort() |> Enum.map_join("", fn {k, v} -> " #{k}:#{v}" end)
end
