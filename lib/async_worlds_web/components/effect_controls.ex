defmodule AsyncWorldsWeb.EffectControls do
  use AsyncWorldsWeb, :html
  alias AsyncWorlds.Quests.EffectAuthoring

  attr :effect, :map, required: true
  attr :form, :any, required: true
  attr :prefix, :string, required: true
  attr :id, :string, required: true
  attr :clocks, :list, required: true
  attr :condition, :boolean, default: false

  def effect_controls(assigns) do
    ~H"""
    <div id={@id} tabindex="-1" class="grid gap-3 rounded-lg border border-white/10 p-3">
      <%= if EffectAuthoring.editable?(@effect) do %>
        <p class="text-sm font-semibold">
          {if @condition, do: "Flag equals (AND)", else: @effect["type"]} · {@effect["key"]}
        </p>
        <p :if={@effect["type"] == "set_flag"} class="whitespace-pre-wrap text-xs text-slate-400">
          {@effect["flag"]["type"]}: {to_string(@effect["flag"]["value"])}{if !@condition,
            do:
              " · " <>
                if(@effect["flag"]["player_visible"] == true, do: "player visible", else: "hidden"),
            else: ""}
        </p>
        <%= if @effect["type"] == "clock_delta" do %>
          <.input
            field={@form[@prefix <> "_clock_id"]}
            id={@id <> "-clock"}
            type="select"
            label="Campaign clock"
            prompt="Choose clock"
            options={Enum.map(@clocks, &{&1.name, &1.id})}
            class="admin-input"
          />
          <.input
            field={@form[@prefix <> "_delta"]}
            id={@id <> "-delta"}
            type="number"
            label="Signed clock delta"
            class="admin-input"
          />
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
