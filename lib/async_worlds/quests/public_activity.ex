defmodule AsyncWorlds.Quests.PublicActivity do
  @moduledoc "Pure public briefing projection; never infer public text from private quest content."

  alias AsyncWorlds.Quests.{Definition, Rules}

  @doc "Only explicitly authored public text and the decision requirement leave this boundary."
  def project(%{"nodes" => nodes} = definition, node_id, status)
      when is_list(nodes) and status in [:active, :completed] do
    case Rules.node(definition, node_id) do
      %{"ending" => ending} = node when is_boolean(ending) ->
        required = status == :active and not ending
        text = node["public_summary"]

        summary =
          if Definition.public_summary?(node) and is_binary(text) and String.trim(text) != "",
            do: text,
            else: fallback(required)

        %{summary: summary, decision_required: required}

      _ ->
        project(nil, nil, nil)
    end
  end

  def project(_, _, _), do: %{summary: fallback(false), decision_required: false}

  defp fallback(true), do: "A quest decision is required."
  defp fallback(false), do: "No quest decision required."
end
