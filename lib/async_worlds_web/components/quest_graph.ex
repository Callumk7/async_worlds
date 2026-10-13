defmodule AsyncWorldsWeb.QuestGraph do
  @moduledoc "Read-only directed quest graph and keyboard-accessible connections."
  use AsyncWorldsWeb, :html
  alias Phoenix.LiveView.JS
  alias AsyncWorlds.Quests.Authoring

  attr :graph, :map, required: true
  attr :definition, :map, required: true

  def graph(assigns) do
    ~H"""
    <section
      id="quest-graph"
      class="rounded-xl border border-sky-300/20 bg-slate-950/40 p-4 space-y-4"
    >
      <h2 class="font-semibold text-sky-200">Directed connections · read-only</h2>
      <p class="text-xs text-slate-400">
        Select a node or connection to focus its form. All outcomes are shown; conditions do not hide edges.
      </p>
      <div class="overflow-auto max-h-[36rem]">
        <svg
          viewBox={"0 0 720 #{max(length(@graph.nodes) * 120, 120)}"}
          class="min-w-[600px] w-full"
          role="img"
          aria-label="Directed quest graph; textual connections below"
        >
          <defs>
            <marker
              id="quest-arrow"
              viewBox="0 0 10 10"
              refX="9"
              refY="5"
              markerWidth="7"
              markerHeight="7"
              orient="auto-start-reverse"
            >
              <path d="M 0 0 L 10 5 L 0 10 z" fill="#7dd3fc" />
            </marker>
          </defs>
          <g :for={{edge, i} <- Enum.with_index(@graph.edges)}>
            <path
              d={edge_path(edge, @graph.nodes, i)}
              stroke={if(destination?(edge, @graph.nodes), do: "#7dd3fc", else: "#fda4af")}
              stroke-opacity="0.5"
              fill="none"
              marker-end="url(#quest-arrow)"
            />
            <text
              x={280 + rem(i, 3) * 115}
              y={edge.node_index * 120 + 28 + rem(i, 4) * 16}
              fill="#cbd5e1"
              font-size="11"
            >
              {String.slice(edge.label || "", 0, 22)} · {edge.outcome} → {edge.destination ||
                "missing"}
            </text>
            <circle
              :if={!destination?(edge, @graph.nodes)}
              cx="685"
              cy={edge.node_index * 120 + 95}
              r="9"
              fill="none"
              stroke="#fda4af"
            />
          </g>
          <a
            :for={node <- @graph.nodes}
            id={"graph-node-#{node.index}"}
            href={"#node-#{node.index}-text"}
            phx-click={JS.focus(to: "#node-#{node.index}-text")}
          >
            <rect
              x="12"
              y={node.index * 120 + 20}
              width="240"
              height="75"
              rx="12"
              fill="#0f172a"
              stroke={if(node.start, do: "#fcd34d", else: "#64748b")}
            />
            <text x="25" y={node.index * 120 + 43} fill="#f8fafc" font-size="14">
              Node {node.index + 1}{if(node.start, do: " · Start", else: "")}{if(node.ending,
                do: " · Ending",
                else: ""
              )}
            </text>
            <text x="25" y={node.index * 120 + 68} fill="#94a3b8" font-size="12">
              {String.slice(node.text || "", 0, 28)}
            </text>
          </a>
        </svg>
      </div>
      <ul id="graph-nodes" class="flex flex-wrap gap-3 text-xs text-slate-300">
        <li :for={node <- @graph.nodes}>
          <a
            id={"graph-node-text-#{node.index}"}
            href={"#node-#{node.index}-text"}
            phx-click={JS.focus(to: "#node-#{node.index}-text")}
            class="underline"
          >Node {node.index + 1} · {node.id}{if(node.start, do: " · Start", else: "")}{if(node.ending,
            do: " · Ending",
            else: ""
          )}</a>
        </li>
      </ul>
      <ul id="graph-connections" class="text-xs text-slate-300 space-y-2">
        <li :for={{edge, i} <- Enum.with_index(@graph.edges)} id={"graph-edge-#{i}"}>
          <a
            href={"##{edge_target(edge)}"}
            phx-click={JS.focus(to: "##{edge_target(edge)}")}
            class="hover:text-sky-200 underline"
          >Node {edge.node_index + 1} · {edge.label} · {edge.outcome} → {edge.destination || "missing"}</a>
        </li>
      </ul>
      <ul id="graph-diagnostics" class="text-sm space-y-2" aria-live="polite">
        <li
          :for={{d, i} <- Enum.with_index(@graph.errors ++ @graph.warnings)}
          id={"graph-diagnostic-#{i}"}
          class={if(d.severity == :error, do: "text-rose-300", else: "text-amber-200")}
        >
          <a
            href={"##{target(d.path, @definition)}"}
            phx-click={JS.focus(to: "##{target(d.path, @definition)}")}
            class="underline break-all"
          >{if(d.severity == :error, do: "Release blocker", else: "Warning (nonblocking)")} · {d.path}: {d.message}</a>
        </li>
      </ul>
    </section>
    """
  end

  def target("start_node", _definition), do: "quest-start-node"
  def target("name", _definition), do: "quest-name"
  def target("content_id", _definition), do: "quest-content-id"

  def target(path, definition) do
    case Regex.run(~r/nodes\[(\d+)\](?:\.choices\[(\d+)\])?(.*)/, path) do
      [_, i, j, suffix] when j != "" ->
        choice_target(i, j, suffix, definition)

      [_, i, "", suffix] when suffix in [".choices", ".ending"] ->
        "node-#{i}-ending"

      [_, i | _] ->
        "node-#{i}-text"

      _ ->
        "quest-name"
    end
  end

  defp choice_target(i, j, suffix, definition) do
    choice =
      get_in(definition, [
        "nodes",
        Access.at(String.to_integer(i)),
        "choices",
        Access.at(String.to_integer(j))
      ])

    cond do
      String.starts_with?(suffix, ".conditions") ->
        list_target("choice-#{i}-#{j}", "condition", suffix)

      suffix == ".eligibility" ->
        "choice-#{i}-#{j}-eligibility"

      Authoring.editable?(choice) and String.starts_with?(suffix, ".outcomes.") ->
        case String.split(suffix, ".") do
          ["", "outcomes", kind, field] when field in ["text", "next_node"] ->
            Authoring.outcome_prefix("choice-#{i}-#{j}", kind) <>
              if(field == "text", do: "-text", else: "-destination")

          ["", "outcomes", kind | _] ->
            list_target(Authoring.outcome_prefix("choice-#{i}-#{j}", kind), "effect", suffix)

          _ ->
            "editor-choice-#{i}-#{j}"
        end

      suffix == ".dice" ->
        "choice-#{i}-#{j}-dice"

      String.starts_with?(suffix, ".critical_effects") ->
        critical_target(i, j, suffix)

      String.ends_with?(suffix, "next_node") ->
        "choice-#{i}-#{j}-destination"

      Authoring.editable?(choice) and suffix == ".label" ->
        "choice-#{i}-#{j}-label"

      Authoring.editable?(choice) and suffix == ".outcomes.fixed.text" ->
        "choice-#{i}-#{j}-text"

      true ->
        "editor-choice-#{i}-#{j}"
    end
  end

  defp list_target(prefix, kind, suffix) do
    case Regex.run(~r/\[(\d+)\](.*)/, suffix) do
      [_, index, field] ->
        ending =
          case field do
            ".key" -> "-key"
            ".value" -> "-value"
            ".flag" -> "-value"
            ".flag_type" -> "-type"
            ".clock_id" -> "-clock"
            ".delta" -> "-delta"
            _ -> ""
          end

        prefix <> "-#{kind}-#{index}" <> ending

      _ ->
        prefix <> if(kind == "condition", do: "-conditions", else: "-effects")
    end
  end

  defp critical_target(i, j, suffix) do
    case Regex.run(~r/critical_effects\[(\d+)\](.*)/, suffix) do
      [_, k, field] ->
        ending =
          case field do
            ".clock_id" -> "-clock"
            ".delta" -> "-delta"
            ".key" -> "-key"
            ".flag" -> "-value"
            _ -> ""
          end

        "choice-#{i}-#{j}-critical-#{k}" <> ending

      _ ->
        "choice-#{i}-#{j}-critical"
    end
  end

  defp edge_target(edge), do: "editor-choice-#{edge.node_index}-#{edge.choice_index}"

  defp destination?(edge, nodes), do: Enum.any?(nodes, &(&1.id == edge.destination))

  defp edge_path(edge, nodes, i) do
    source_y = edge.node_index * 120 + 60
    destination = Enum.find(nodes, &(&1.id == edge.destination))
    destination_y = if destination, do: destination.index * 120 + 70, else: source_y + 35
    bend = 340 + rem(i, 12) * 27

    destination_x = if destination, do: 252, else: 674

    "M 252 #{source_y} C #{bend} #{source_y - 65}, #{bend} #{destination_y + 65}, #{destination_x} #{destination_y}"
  end
end
