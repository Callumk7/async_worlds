defmodule AsyncWorldsWeb.AdminComponents do
  @moduledoc false
  use AsyncWorldsWeb, :html

  attr :form, :any, required: true

  def flag_inputs(assigns) do
    ~H"""
    <.input
      field={@form[:type]}
      type="select"
      label="Type"
      options={["boolean", "integer", "string"]}
      class="admin-input"
    />
    <%= if @form[:type].value == "boolean" do %>
      <.input
        field={@form[:value]}
        type="select"
        label="Boolean value"
        options={[True: "true", False: "false"]}
        class="admin-input"
      />
    <% else %>
      <.input
        field={@form[:value]}
        type={if @form[:type].value == "integer", do: "number", else: "textarea"}
        step="1"
        label={
          if @form[:type].value == "integer",
            do: "Whole number",
            else: "String value (no JSON quoting)"
        }
        class="admin-input"
      />
    <% end %>
    <.input
      field={@form[:player_visible]}
      type="select"
      label="Player visibility"
      options={["Hidden (DM only)": "false", "Visible to owner": "true"]}
      class="admin-input"
    />
    """
  end

  attr :active, :string, required: true

  def navigation(assigns) do
    ~H"""
    <nav id="admin-navigation" aria-label="Campaign administration" class="mb-8 flex flex-wrap gap-2">
      <.link
        id="nav-dashboard"
        navigate={~p"/dashboard"}
        aria-current={@active == "dashboard" && "page"}
        class={["admin-tab", @active == "dashboard" && "admin-tab-active"]}
      >
        <.icon name="hero-squares-2x2" class="size-4" /> Overview
      </.link>
      <.link
        id="nav-clocks"
        navigate={~p"/clocks"}
        aria-current={@active == "clocks" && "page"}
        class={["admin-tab", @active == "clocks" && "admin-tab-active"]}
      >
        <.icon name="hero-clock" class="size-4" /> Clocks
      </.link>
      <.link
        id="nav-characters"
        navigate={~p"/characters"}
        aria-current={@active == "characters" && "page"}
        class={["admin-tab", @active == "characters" && "admin-tab-active"]}
      >
        <.icon name="hero-user-group" class="size-4" /> Characters
      </.link>
      <.link
        id="nav-quests"
        navigate={~p"/quests"}
        aria-current={@active == "quests" && "page"}
        class={["admin-tab", @active == "quests" && "admin-tab-active"]}
      >
        <.icon name="hero-map" class="size-4" /> Quests
      </.link>
      <.link
        id="nav-history"
        navigate={~p"/ticks/history"}
        aria-current={@active == "history" && "page"}
        class={["admin-tab", @active == "history" && "admin-tab-active"]}
      >
        <.icon name="hero-archive-box" class="size-4" /> History
      </.link>
    </nav>
    """
  end

  def error_message(%Ecto.Changeset{}), do: "Check the highlighted fields and try again."

  def error_message(:stale_character),
    do:
      "Character changed in another tab or published tick. Reopen the character and inspect it before saving; your changes were not applied."

  def error_message(:invalid_flag_key),
    do:
      "Use a lowercase key starting with a letter, with digits/underscores only (maximum 64 bytes)."

  def error_message(:invalid_flag_integer),
    do: "Enter a whole number between -9007199254740991 and 9007199254740991."

  def error_message(:invalid_flag_string),
    do: "String must be valid UTF-8, at most 2000 bytes, without NUL characters."

  def error_message(:invalid_flag_visibility),
    do: "Choose Hidden (DM only) or Visible to owner explicitly."

  def error_message(:invalid_flag_value),
    do: "Choose boolean true/false, a whole number, or an ordinary string."

  def error_message(:invalid_flag),
    do: "Fact not saved. Check key, type, value and explicit visibility (maximum 100 facts)."

  def error_message(:stale_draft),
    do:
      "This draft changed in another window. Reload the review, inspect the new revision, and try again."

  def error_message(:stale_identity),
    do: "This frozen quest or selected die identity is stale. Reload the review before editing."

  def error_message(:stale_input),
    do: "The input revision does not match this frozen tick. Reload and inspect the review."

  def error_message(:stale_delivery),
    do: "This delivery changed. Refresh its status before retrying."

  def error_message(:stale_live_state),
    do:
      "Live clocks, characters, quest positions or campaign routing no longer match the frozen inputs. Restore compatible configuration before publishing."

  def error_message(:stale_clock),
    do: "This clock changed in another window. Select it again before saving."

  def error_message(:tick_locked),
    do:
      "Clock, character and quest management is locked during resolution and review. Publish the active tick before intervening."

  def error_message(:stale_progression),
    do:
      "This character's quest or position changed in another window. Inspect the refreshed assignment before trying again."

  def error_message(:active_quest),
    do:
      "This character already has an active quest. Refresh and use Replace quest, or end the current assignment first."

  def error_message(:not_active),
    do: "This quest is no longer active. Refresh the character and assign a new quest if needed."

  def error_message(:invalid_node),
    do:
      "Choose a node from this character's pinned quest revision. Refresh to see the current nodes."

  def error_message(:completed),
    do: "Reset this completed clock before editing. Reset also resets its racing partner."

  def error_message(:already_paired),
    do: "One of these clocks is already in a race. Unpair it first."

  def error_message(:self_link), do: "Choose two different clocks."
  def error_message(:invalid_delta), do: "Enter a whole-number clock delta."

  def error_message(:invalid_edit),
    do:
      "Choose a configured quest outcome, valid narration/news, or an eligible clock with a whole-number delta. Text must be at most 2000 characters."

  def error_message(:invalid_reason), do: "An audit reason is required (at most 2000 characters)."

  def error_message(:confirmation_required),
    do:
      "Confirm that you checked Discord and accept a possible duplicate before retrying an ambiguous send."

  def error_message(:not_retryable),
    do: "Only failed or explicitly confirmed ambiguous deliveries can be retried."

  def error_message(:invalid_filter),
    do: "That delivery filter is not supported. Refresh and choose from the listed options."

  def error_message(:already_published),
    do: "This tick is already published. Do not republish to retry delivery."

  def error_message(:quest_publication_required),
    do:
      "Quest publication is not available yet. This draft contains quest submissions or quest-dependent triggers and cannot be published until quest publication is implemented."

  def error_message(:invalid_draft),
    do:
      "The draft is not a valid audited resolution. Publication is blocked; investigate the resolution before continuing."

  def error_message(:not_found),
    do: "That record is not available in this campaign. Refresh and try again."

  def error_message(:active_tick),
    do: "Finish and publish the active tick before opening another."

  def error_message({:invalid_transition, _, _}),
    do: "The tick has moved to another stage. Refresh before continuing."

  def error_message(_),
    do: "The operation could not be completed. Refresh and check the current campaign state."

  def params_form(params, fields, opts) do
    types = Map.new(fields, &{&1, :string})

    {%{}, types}
    |> Ecto.Changeset.cast(params, fields)
    |> to_form(opts)
  end

  def integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> {:ok, number}
      _ -> {:error, :invalid_delta}
    end
  end

  def integer(_), do: {:error, :invalid_delta}
end
