defmodule AsyncWorldsWeb.EffectControls do
  use AsyncWorldsWeb, :html
  alias AsyncWorlds.Quests.{EffectAuthoring, ConditionAuthoring}

  def clock_label(clock) do
    privacy =
      case clock.visibility do
        :public -> "public: identity and fill visible"
        :known -> "known: fill private"
        :hidden -> "hidden: identity and fill private"
      end

    "#{clock.name} · #{clock.segments} segments · #{privacy}"
  end

  defp clock_options(clocks, selected) do
    options = Enum.map(clocks, &{clock_label(&1), &1.id})

    if selected in [nil, "", 0] or Enum.any?(clocks, &(to_string(&1.id) == to_string(selected))),
      do: options,
      else: [{"Missing campaign clock — choose a replacement", selected} | options]
  end

  defp comparison_options(operator) do
    options = [{"At least (gte)", "gte"}, {"At most (lte)", "lte"}]

    if operator in ~w(gte lte),
      do: options,
      else: [{"Invalid comparison — choose a replacement", operator} | options]
  end

  defp clock_summary(effect, clocks) do
    case Enum.find(clocks, &(&1.id == effect["clock_id"])) do
      nil -> "Missing or unselected campaign clock"
      clock -> clock_label(clock)
    end
  end

  defp clock_operation(%{"type" => "clock_delta", "delta" => delta})
       when is_integer(delta) and delta > 0,
       do: "add +#{delta} segments"

  defp clock_operation(%{"type" => "clock_delta", "delta" => delta}),
    do: "delta #{delta} segments"

  defp clock_operation(%{"operator" => "gte", "value" => value}), do: "fill at least #{value}"
  defp clock_operation(%{"operator" => "lte", "value" => value}), do: "fill at most #{value}"
  defp clock_operation(_), do: "invalid comparison — choose at least or at most"

  attr :effect, :map, required: true
  attr :form, :any, required: true
  attr :prefix, :string, required: true
  attr :id, :string, required: true
  attr :clocks, :list, required: true
  attr :condition, :boolean, default: false

  def effect_controls(assigns) do
    ~H"""
    <div id={@id} tabindex="-1" class="grid gap-3 rounded-lg border border-white/10 p-3">
      <%= if EffectAuthoring.editable?(@effect) or (@condition and ConditionAuthoring.editable?(@effect)) do %>
        <p class="text-sm font-semibold">
          {cond do
            @effect["type"] == "clock_threshold" -> "Clock threshold (AND)"
            @condition -> "Flag equals (AND)"
            true -> @effect["type"]
          end} · {@effect["key"]}
        </p>
        <p :if={@effect["type"] == "set_flag"} class="whitespace-pre-wrap text-xs text-slate-400">
          {@effect["flag"]["type"]}: {to_string(@effect["flag"]["value"])}{if !@condition,
            do:
              " · " <>
                if(@effect["flag"]["player_visible"] == true, do: "player visible", else: "hidden"),
            else: ""}
        </p>
        <%= if @effect["type"] in ~w(clock_delta clock_threshold) do %>
          <p id={@id <> "-summary"} class="text-xs text-slate-400">
            {clock_summary(@effect, @clocks)} · {clock_operation(@effect)}
          </p>
          <.input
            field={@form[@prefix <> "_clock_id"]}
            id={@id <> "-clock"}
            type="select"
            label="Campaign clock"
            prompt="Choose clock"
            options={clock_options(@clocks, @effect["clock_id"])}
            class="admin-input"
          />
          <%= if @effect["type"] == "clock_threshold" do %>
            <.input
              field={@form[@prefix <> "_operator"]}
              id={@id <> "-operator"}
              type="select"
              label="Comparison"
              options={comparison_options(@effect["operator"])}
              class="admin-input"
            />
            <.input
              field={@form[@prefix <> "_value"]}
              id={@id <> "-value"}
              type="number"
              min="0"
              step="1"
              label="Integer threshold (0 through current clock size at release)"
              class="admin-input"
            />
          <% else %>
            <.input
              field={@form[@prefix <> "_delta"]}
              id={@id <> "-delta"}
              type="number"
              step="1"
              label="Signed integer clock delta"
              class="admin-input"
            />
          <% end %>
        <% else %>
          <.input
            field={@form[@prefix <> "_key"]}
            id={@id <> "-key"}
            label="Flag key"
            class="admin-input"
          />
          <%= if @effect["type"] == "set_flag" do %>
            <.input
              field={@form[@prefix <> "_flag_type"]}
              id={@id <> "-type"}
              type="select"
              label="Flag type"
              options={~w(boolean integer string)}
              class="admin-input"
            />
            <.input
              field={@form[@prefix <> "_value"]}
              id={@id <> "-value"}
              type={
                case @effect["flag"]["type"] do
                  "string" -> "textarea"
                  "boolean" -> "select"
                  _ -> "number"
                end
              }
              options={[{"True", "true"}, {"False", "false"}]}
              label="Typed value (strings are plain text)"
              class="admin-input"
            />
            <.input
              :if={!@condition}
              field={@form[@prefix <> "_visible"]}
              id={@id <> "-visible"}
              type="select"
              label="Player visible"
              options={[{"No", "false"}, {"Yes", "true"}]}
              class="admin-input"
            />
          <% end %>
        <% end %>
      <% else %>
        <p class="text-sm text-sky-200">Imported unsupported effect preserved read-only.</p>
      <% end %>
    </div>
    """
  end
end
