defmodule AsyncWorldsWeb.AdminComponents do
  @moduledoc false
  use AsyncWorldsWeb, :html

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
    </nav>
    """
  end

  def error_message(%Ecto.Changeset{}), do: "Check the highlighted fields and try again."

  def error_message(:stale_draft),
    do:
      "This draft changed in another window. Reload the review, inspect the new revision, and try again."

  def error_message(:stale_delivery),
    do: "This delivery changed. Refresh its status before retrying."

  def error_message(:stale_live_state),
    do:
      "Live clocks or campaign routing no longer match the frozen inputs. Restore compatible configuration before publishing."

  def error_message(:stale_clock),
    do: "This clock changed in another window. Select it again before saving."

  def error_message(:tick_locked),
    do:
      "Clock management is locked during resolution and review. Make result changes in the review instead."

  def error_message(:completed),
    do: "Reset this completed clock before editing. Reset also resets its racing partner."

  def error_message(:already_paired),
    do: "One of these clocks is already in a race. Unpair it first."

  def error_message(:self_link), do: "Choose two different clocks."
  def error_message(:invalid_delta), do: "Enter a whole-number clock delta."

  def error_message(:invalid_edit),
    do:
      "Choose an eligible clock and a whole-number delta, or valid news paragraphs (at most 2000 characters each)."

  def error_message(:invalid_reason), do: "An audit reason is required (at most 2000 characters)."

  def error_message(:confirmation_required),
    do:
      "Confirm that you checked Discord and accept a possible duplicate before retrying an ambiguous send."

  def error_message(:not_retryable),
    do: "Only failed or explicitly confirmed ambiguous deliveries can be retried."

  def error_message(:already_published),
    do: "This tick is already published. Do not republish to retry delivery."

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
