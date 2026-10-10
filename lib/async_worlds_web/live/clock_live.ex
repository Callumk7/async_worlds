defmodule AsyncWorldsWeb.ClockLive do
  use AsyncWorldsWeb, :live_view
  import AsyncWorldsWeb.AdminComponents
  alias AsyncWorlds.{Clocks, Ticks}
  alias AsyncWorlds.Clocks.{Clock, Trigger}
  import Ecto.Changeset, only: [get_field: 2, put_embed: 3]

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(page_title: "World clocks", editing: nil) |> refresh() |> new_form()}
  end

  @impl true
  def handle_event("refresh", _, socket), do: {:noreply, socket |> refresh() |> new_form()}
  def handle_event("new", _, socket), do: {:noreply, new_form(socket)}

  def handle_event("edit", %{"id" => id}, socket) do
    case find_clock(socket, id) do
      {:ok, clock} ->
        {:noreply, socket |> assign(editing: clock, form: to_form(Clock.changeset(clock, %{})))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  def handle_event("validate", %{"clock" => params}, socket) do
    changeset = Clock.changeset(socket.assigns.editing || %Clock{}, params)
    {:noreply, assign(socket, :form, to_form(%{changeset | action: :validate}))}
  end

  def handle_event("add_trigger", _, socket) do
    changeset = socket.assigns.form.source
    triggers = get_field(changeset, :triggers) ++ [%Trigger{type: :world_news}]
    {:noreply, assign(socket, :form, to_form(put_embed(changeset, :triggers, triggers)))}
  end

  def handle_event("remove_trigger", %{"index" => index}, socket) do
    with {:ok, index} <- integer(index) do
      changeset = socket.assigns.form.source
      triggers = get_field(changeset, :triggers) |> List.delete_at(index)
      {:noreply, assign(socket, :form, to_form(put_embed(changeset, :triggers, triggers)))}
    else
      _ -> {:noreply, put_flash(socket, :error, "Invalid trigger selection.")}
    end
  end

  def handle_event("save", %{"clock" => params}, socket) do
    # An empty trigger editor must explicitly replace the stored embeds.
    params = Map.put_new(params, "triggers", [])

    result =
      if clock = socket.assigns.editing do
        Clocks.edit_clock(campaign_id(socket), clock.id, params, source(socket), clock)
      else
        Clocks.create_clock(campaign_id(socket), params, source(socket))
      end

    case result do
      {:ok, _} ->
        {:noreply, socket |> refresh() |> new_form() |> put_flash(:info, "Clock saved.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        socket = assign(socket, :form, to_form(%{changeset | action: :insert}))

        socket =
          if Keyword.has_key?(changeset.errors, :triggers),
            do:
              put_flash(
                socket,
                :error,
                "Trigger targets must reference another clock in this campaign."
              ),
            else: socket

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, socket |> refresh() |> put_flash(:error, error_message(reason))}
    end
  end

  def handle_event("adjust", %{"id" => id, "adjust" => params}, socket) do
    result =
      with {:ok, clock} <- find_clock(socket, id),
           {:ok, delta} <- integer(params["delta"]),
           do: Clocks.adjust_clock(campaign_id(socket), clock.id, delta, source(socket))

    {:noreply, complete(socket, result, "Clock fill adjusted.")}
  end

  def handle_event("pause", %{"id" => id, "paused" => paused}, socket)
      when paused in ["true", "false"] do
    result =
      with {:ok, clock} <- find_clock(socket, id),
           do:
             Clocks.edit_clock(
               campaign_id(socket),
               clock.id,
               %{paused: paused == "true"},
               source(socket),
               clock
             )

    {:noreply, complete(socket, result, "Clock pause updated.")}
  end

  def handle_event("reset", %{"id" => id}, socket) do
    result =
      with {:ok, clock} <- find_clock(socket, id),
           do: Clocks.reset_clock(campaign_id(socket), clock.id, source(socket))

    {:noreply, complete(socket, result, "Clock reset (including its racing partner, if paired).")}
  end

  def handle_event("pair", %{"race" => params}, socket) do
    result =
      with {:ok, first} <- integer(params["first_id"]),
           {:ok, second} <- integer(params["second_id"]),
           do: Clocks.pair_clocks(campaign_id(socket), first, second, source(socket))

    {:noreply,
     complete(socket, result, "Racing clocks linked. Only the winning clock fires its triggers.")}
  end

  def handle_event("unpair", %{"id" => id}, socket) do
    result =
      with {:ok, clock} <- find_clock(socket, id),
           do: Clocks.unpair_clock(campaign_id(socket), clock.id, source(socket))

    {:noreply, complete(socket, result, "Racing clocks unlinked.")}
  end

  def handle_event(_, _, socket),
    do: {:noreply, put_flash(socket, :error, "Invalid action. Refresh and try again.")}

  defp complete(socket, {:ok, _}, message),
    do: socket |> refresh() |> new_form() |> put_flash(:info, message)

  defp complete(socket, {:error, reason}, _),
    do: socket |> refresh() |> put_flash(:error, error_message(reason))

  defp campaign_id(socket), do: socket.assigns.current_scope.campaign.id
  defp source(socket), do: "dm:web:#{socket.assigns.current_scope.discord_user_id}"

  defp find_clock(socket, id) do
    with {:ok, id} <- integer(id),
         clock when not is_nil(clock) <-
           Enum.find(Clocks.list_clocks(campaign_id(socket)), &(&1.id == id)) do
      {:ok, clock}
    else
      _ -> {:error, :not_found}
    end
  end

  defp new_form(socket),
    do: assign(socket, editing: nil, form: to_form(Clock.changeset(%Clock{}, %{})))

  defp refresh(socket) do
    id = campaign_id(socket)
    tick = Ticks.active_tick(id)
    clocks = Clocks.list_clocks(id)

    items =
      Enum.map(clocks, fn clock ->
        %{
          id: clock.id,
          clock: clock,
          form:
            params_form(%{"delta" => "1"}, [:delta], as: :adjust, id: "adjust-clock-#{clock.id}")
        }
      end)

    socket
    |> assign(
      locked:
        (tick && tick.status in [:resolving, :in_review]) ||
          socket.assigns.current_scope.campaign.clock_mutations_locked,
      clock_options: Enum.map(clocks, &{&1.name, &1.id}),
      race_options:
        clocks |> Enum.reject(&(&1.completed || &1.racing_group)) |> Enum.map(&{&1.name, &1.id}),
      race_form:
        params_form(%{"first_id" => "", "second_id" => ""}, [:first_id, :second_id], as: :race)
    )
    |> stream(:clocks, items, reset: true)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.navigation active="clocks" />
      <section id="clock-management" class="space-y-7">
        <header class="flex flex-wrap justify-between gap-4">
          <div>
            <p class="text-xs uppercase tracking-widest text-amber-300">World machinery</p><h1 class="mt-2 text-4xl font-semibold tracking-tight">
              Clocks & consequences
            </h1><p class="mt-3 text-sm text-slate-400">
              Configure live inputs before closing. Review edits never change these inputs.
            </p>
          </div><button
            id="refresh-clocks"
            phx-click="refresh"
            class="admin-button admin-secondary self-start"
          >Refresh</button>
        </header>
        <p
          :if={@locked}
          id="clock-lock-notice"
          role="status"
          class="rounded-xl border border-amber-300/30 bg-amber-300/10 p-4 text-sm text-amber-200"
        >
          Management locked during resolution/review. Use the draft review to change this tick's result.
        </p>
        <div class="grid gap-7 lg:grid-cols-[1fr_1.1fr]">
          <section class="admin-panel">
            <div class="mb-5 flex justify-between gap-4">
              <h2 class="text-xl font-semibold">
                {if @editing, do: "Edit #{@editing.name}", else: "Create a clock"}
              </h2><button
                :if={@editing}
                id="new-clock"
                phx-click="new"
                class="text-sm text-amber-300"
              >New clock</button>
            </div>
            <.form
              for={@form}
              id="clock-form"
              phx-change="validate"
              phx-submit="save"
              class="admin-form space-y-4"
            >
              <fieldset disabled={@locked || (@editing && @editing.completed)} class="space-y-4">
                <.input
                  field={@form[:name]}
                  label="Clock name"
                  required
                  maxlength="200"
                  class="admin-input"
                  error_class="admin-input-error"
                />
                <div class="grid grid-cols-2 gap-4">
                  <.input
                    field={@form[:segments]}
                    type="select"
                    label="Segments"
                    options={[4, 6, 8]}
                    class="admin-input"
                    error_class="admin-input-error"
                  /><.input
                    field={@form[:filled]}
                    type="number"
                    label="Current fill (clamped to size)"
                    class="admin-input"
                    error_class="admin-input-error"
                  />
                </div>
                <div class="grid grid-cols-2 gap-4">
                  <.input
                    field={@form[:visibility]}
                    type="select"
                    label="Visibility"
                    options={[Public: :public, "Known (name only)": :known, Hidden: :hidden]}
                    class="admin-input"
                    error_class="admin-input-error"
                  /><.input
                    field={@form[:background_rate]}
                    type="number"
                    label="Signed change each tick"
                    class="admin-input"
                    error_class="admin-input-error"
                  />
                </div>
                <.input
                  field={@form[:paused]}
                  type="checkbox"
                  label="Paused (skip background rate)"
                  class="admin-checkbox"
                />
                <div class="flex items-center justify-between">
                  <h3 class="text-sm font-semibold">When filled</h3><button
                    id="add-trigger"
                    type="button"
                    phx-click="add_trigger"
                    class="admin-button admin-secondary"
                  ><.icon name="hero-plus" class="size-4" /> Add trigger</button>
                </div>
                <p class="text-xs text-slate-400">
                  World news is public narration, even for a hidden source. Starting a clock unpauses it without applying another rate.
                </p>
                <.inputs_for :let={trigger_form} field={@form[:triggers]}>
                  <div
                    id={"trigger-#{trigger_form.index}"}
                    class="space-y-3 rounded-xl border border-white/10 p-3"
                  >
                    <.input
                      field={trigger_form[:type]}
                      type="select"
                      label="Action"
                      options={[
                        "World news": :world_news,
                        "Notify DM": :notify_dm,
                        "Start clock": :start_clock
                      ]}
                      class="admin-input"
                      error_class="admin-input-error"
                    />
                    <%= if to_string(trigger_form[:type].value) == "start_clock" do %>
                      <.input
                        field={trigger_form[:clock_id]}
                        type="select"
                        label="Target clock"
                        prompt="Choose a target"
                        options={
                          Enum.reject(@clock_options, fn {_, id} -> @editing && @editing.id == id end)
                        }
                        class="admin-input"
                        error_class="admin-input-error"
                      />
                      <.input field={trigger_form[:text]} type="hidden" value="" />
                    <% else %>
                      <.input
                        field={trigger_form[:text]}
                        type="textarea"
                        label="Notification / public news text"
                        maxlength="2000"
                        class="admin-input"
                        error_class="admin-input-error"
                      />
                      <.input field={trigger_form[:clock_id]} type="hidden" value="" />
                    <% end %>
                    <button
                      id={"remove-trigger-#{trigger_form.index}"}
                      type="button"
                      phx-click="remove_trigger"
                      phx-value-index={trigger_form.index}
                      class="text-xs text-rose-300 hover:text-rose-100"
                    >Remove trigger</button>
                  </div>
                </.inputs_for>
                <button id="save-clock" phx-disable-with="Saving…" class="admin-button">Save clock</button>
              </fieldset>
            </.form>
            <p
              :if={@editing && @editing.completed}
              id="completed-clock-notice"
              class="mt-4 text-sm text-amber-200"
            >
              Reset this clock before editing it.
            </p>
          </section>
          <div class="space-y-7">
            <section class="admin-panel">
              <h2 class="mb-5 text-xl font-semibold">Live clock controls</h2>
              <div id="managed-clocks" phx-update="stream" class="space-y-4">
                <p id="managed-clocks-empty" class="hidden only:block text-sm text-slate-400">
                  No clocks yet. Start with a public progress clock.
                </p>
                <article
                  :for={{dom_id, item} <- @streams.clocks}
                  id={dom_id}
                  class="rounded-xl border border-white/10 p-4"
                >
                  <div class="flex justify-between gap-3">
                    <h3 class="font-semibold">{item.clock.name}</h3><span class="text-amber-200 tabular-nums">{item.clock.filled}/{item.clock.segments}</span>
                  </div>
                  <p class="mt-1 text-xs text-slate-400">
                    {item.clock.visibility} · rate {item.clock.background_rate} · {if item.clock.completed,
                      do: "completed",
                      else: if(item.clock.paused, do: "paused", else: "running")}
                    <span :if={item.clock.racing_group}>· racing pair</span>
                  </p>
                  <div class="mt-4 flex flex-wrap gap-2">
                    <button
                      id={"edit-clock-#{item.id}"}
                      phx-click="edit"
                      phx-value-id={item.id}
                      disabled={@locked || item.clock.completed}
                      class="admin-button admin-secondary"
                    >Edit</button>
                    <button
                      id={"pause-clock-#{item.id}"}
                      phx-click="pause"
                      phx-value-id={item.id}
                      phx-value-paused={to_string(not item.clock.paused)}
                      disabled={@locked || item.clock.completed}
                      class="admin-button admin-secondary"
                    >{if item.clock.paused, do: "Resume", else: "Pause"}</button>
                    <button
                      id={"reset-clock-#{item.id}"}
                      phx-click="reset"
                      phx-value-id={item.id}
                      disabled={@locked}
                      data-confirm="Reset fill and completion for this clock and its racing partner?"
                      class="admin-button admin-danger"
                    >Reset</button>
                    <button
                      :if={item.clock.racing_group}
                      id={"unpair-clock-#{item.id}"}
                      phx-click="unpair"
                      phx-value-id={item.id}
                      disabled={@locked}
                      class="admin-button admin-secondary"
                    >Unpair</button>
                  </div>
                  <.form
                    for={item.form}
                    id={"adjust-clock-#{item.id}"}
                    phx-submit="adjust"
                    phx-value-id={item.id}
                    class="admin-form mt-4 flex items-end gap-3"
                  >
                    <.input
                      field={item.form[:delta]}
                      type="number"
                      label="Signed adjustment"
                      disabled={@locked || item.clock.completed}
                      class="admin-input"
                    />
                    <button
                      id={"adjust-clock-button-#{item.id}"}
                      disabled={@locked || item.clock.completed}
                      class="admin-button admin-secondary mb-2"
                    >Apply</button>
                  </.form>
                </article>
              </div>
            </section>
            <section class="admin-panel">
              <h2 class="mb-3 text-lg font-semibold">Link a racing pair</h2><p class="mb-4 text-sm text-slate-400">
                The first clock to fill wins; both complete, only the winner triggers.
              </p>
              <.form for={@race_form} id="race-form" phx-submit="pair" class="admin-form space-y-4">
                <.input
                  field={@race_form[:first_id]}
                  type="select"
                  label="First clock"
                  prompt="Select a clock"
                  options={@race_options}
                  disabled={@locked}
                  class="admin-input"
                />
                <.input
                  field={@race_form[:second_id]}
                  type="select"
                  label="Second clock"
                  prompt="Select a different clock"
                  options={@race_options}
                  disabled={@locked}
                  class="admin-input"
                />
                <button
                  id="pair-clocks"
                  disabled={@locked || length(@race_options) < 2}
                  class="admin-button admin-secondary"
                >Link race</button>
              </.form>
            </section>
          </div>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
