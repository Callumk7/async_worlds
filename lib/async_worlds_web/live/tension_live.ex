defmodule AsyncWorldsWeb.TensionLive do
  use AsyncWorldsWeb, :live_view
  import AsyncWorldsWeb.AdminComponents
  alias AsyncWorlds.DM.{Clocks, Tensions, Ticks}
  alias AsyncWorlds.Clocks.Clock
  alias AsyncWorlds.Tensions.Tension

  @impl true
  def mount(_, _, socket) do
    {:ok, assign(socket, page_title: "Tensions", tension: nil, editing_clock: nil)}
  end

  @impl true
  def handle_params(params, _, socket) do
    case params do
      %{"id" => id} ->
        case Tensions.get_tension(socket.assigns.current_scope, id) do
          {:ok, tension} ->
            {:noreply, socket |> assign(tension: tension) |> refresh()}

          {:error, _} ->
            {:noreply,
             socket |> put_flash(:error, "Tension not found.") |> push_navigate(to: ~p"/tensions")}
        end

      _ ->
        {:noreply, socket |> assign(tension: nil) |> refresh()}
    end
  end

  @impl true
  def handle_event("save", %{"tension" => attrs}, socket) do
    result =
      if t = socket.assigns.tension,
        do: Tensions.edit_tension(scope(socket), t.id, attrs, t),
        else: Tensions.create_tension(scope(socket), attrs)

    case result do
      {:ok, t} ->
        {:noreply,
         socket |> put_flash(:info, "Tension saved.") |> push_navigate(to: ~p"/tensions/#{t.id}")}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign(socket, form: to_form(%{cs | action: :insert}))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  def handle_event("edit-clock", %{"id" => id}, %{assigns: %{tension: %Tension{}}} = socket) do
    with {:ok, id} <- AsyncWorlds.ScopedID.cast(id),
         %Clock{} = clock <- socket.assigns.clock_versions[id],
         true <- clock.tension_id == socket.assigns.tension.id do
      {:noreply,
       assign(socket, editing_clock: clock, clock_form: to_form(Clock.changeset(clock, %{})))}
    else
      _ -> {:noreply, put_flash(socket, :error, "Clock not found.")}
    end
  end

  def handle_event("new-clock", _, %{assigns: %{tension: %Tension{}}} = socket),
    do: {:noreply, new_clock_form(socket)}

  def handle_event("save-clock", %{"clock" => attrs}, %{assigns: %{tension: %Tension{}}} = socket) do
    result =
      if clock = socket.assigns.editing_clock,
        do: Clocks.edit_clock(scope(socket), clock.id, attrs, :web, clock),
        else: Tensions.create_clock(scope(socket), socket.assigns.tension.id, attrs)

    case result do
      {:ok, _} ->
        {:noreply, socket |> refresh() |> put_flash(:info, "Clock saved.")}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign(socket, clock_form: to_form(%{cs | action: :insert}))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  def handle_event(
        "associate",
        %{"association" => %{"clock_id" => id}},
        %{assigns: %{tension: %Tension{}}} = socket
      ),
      do: associate(socket, id, socket.assigns.tension.id)

  def handle_event("detach", %{"id" => id}, %{assigns: %{tension: %Tension{}}} = socket),
    do: associate(socket, id, nil)

  def handle_event("refresh", _, socket) do
    tension =
      case socket.assigns.tension do
        nil ->
          nil

        t ->
          case Tensions.get_tension(scope(socket), t.id) do
            {:ok, fresh} -> fresh
            _ -> t
          end
      end

    {:noreply, socket |> assign(tension: tension) |> refresh()}
  end

  def handle_event(_, _, socket), do: {:noreply, put_flash(socket, :error, "Invalid action.")}

  defp associate(socket, id, target) do
    result =
      with {:ok, id} <- AsyncWorlds.ScopedID.cast(id),
           %Clock{} = clock <- socket.assigns.clock_versions[id],
           do: Tensions.associate_clock(scope(socket), id, target, clock)

    case result do
      {:ok, _} -> {:noreply, refresh(socket)}
      {:error, reason} -> {:noreply, put_flash(socket, :error, error_message(reason))}
      _ -> {:noreply, put_flash(socket, :error, "Clock not found.")}
    end
  end

  defp scope(socket), do: socket.assigns.current_scope

  defp new_clock_form(socket),
    do:
      assign(socket,
        editing_clock: nil,
        clock_form: to_form(Clock.changeset(%Clock{visibility: :hidden, segments: 6}, %{}))
      )

  defp refresh(socket) do
    {:ok, tensions} = Tensions.list_tensions(scope(socket))
    {:ok, clocks} = Clocks.list_clocks(scope(socket))
    {:ok, tick} = Ticks.active_tick(scope(socket))
    tension = socket.assigns.tension

    socket
    |> assign(
      form: to_form(Tension.changeset(tension || %Tension{}, %{})),
      locked:
        (tick && tick.status in [:resolving, :in_review]) ||
          scope(socket).campaign.clock_mutations_locked,
      clock_versions: Map.new(clocks, &{&1.id, &1}),
      association_form: to_form(%{"clock_id" => ""}, as: :association),
      standalone_options:
        clocks
        |> Enum.filter(&(is_nil(&1.tension_id) and not &1.completed))
        |> Enum.map(&{&1.name, &1.id})
    )
    |> stream(:tensions, tensions, reset: true)
    |> stream(:clocks, Enum.filter(clocks, &(tension && &1.tension_id == tension.id)),
      reset: true
    )
    |> new_clock_form()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.navigation active="tensions" />
      <section id="tension-management" class="space-y-7">
        <header class="flex justify-between gap-4">
          <div>
            <p class="text-xs uppercase tracking-widest text-amber-300">Private DM workspace</p>
            <h1 class="mt-2 text-4xl font-semibold">
              {if @tension, do: @tension.name, else: "Tensions"}
            </h1>
            <p class="mt-3 text-sm text-slate-400">
              Ongoing situations, not locations or quests. Resolution will be established through tick publication.
            </p>
          </div>
          <button
            id="refresh-tensions"
            phx-click="refresh"
            class="admin-button admin-secondary self-start"
          >Refresh</button>
        </header>
        <p :if={@locked} id="tension-lock-notice" class="admin-panel text-amber-200">
          Management locked during resolution/review.
        </p>
        <div class="grid gap-7 lg:grid-cols-[1fr_2fr]">
          <aside class="admin-panel space-y-4">
            <.link id="new-tension" navigate={~p"/tensions"} class="admin-button admin-secondary">New Tension</.link>
            <div id="tensions" phx-update="stream" class="space-y-3">
              <p id="tensions-empty" class="hidden only:block text-slate-400">No situations yet.</p>
              <article
                :for={{dom_id, tension} <- @streams.tensions}
                id={dom_id}
                class="rounded-xl border border-white/10 p-4"
              >
                <.link
                  id={"show-tension-#{tension.id}"}
                  navigate={~p"/tensions/#{tension.id}"}
                  class="text-amber-200 hover:text-amber-100 transition"
                >{tension.name}</.link>
                <p class="text-xs text-slate-400">{tension.status}</p>
              </article>
            </div>
          </aside>
          <div class="space-y-7">
            <section class="admin-panel space-y-4">
              <div :if={@tension} id="tension-detail" class="space-y-3">
                <p id="tension-status" class="text-amber-200">{@tension.status} · DM only</p>
                <.link
                  id="tension-history-link"
                  navigate={~p"/tensions/#{@tension.id}/history"}
                  class="text-sm text-amber-200 hover:underline"
                >Read this Tension’s chronicle</.link>
                <p id="tension-circumstances" class="whitespace-pre-wrap text-slate-300">
                  {@tension.description}
                </p>
              </div>
              <h2 class="text-xl font-semibold">
                {if @tension, do: "Edit current circumstances", else: "Open a situation"}
              </h2>
              <.form for={@form} id="tension-form" phx-submit="save" class="admin-form space-y-4">
                <fieldset disabled={@locked} class="space-y-4">
                  <.input
                    field={@form[:name]}
                    label="Name"
                    required
                    maxlength="200"
                    class="admin-input"
                  />
                  <.input
                    field={@form[:description]}
                    type="textarea"
                    label="Description / current circumstances"
                    class="admin-input"
                  />
                  <button id="save-tension" class="admin-button" phx-disable-with="Saving…">Save Tension</button>
                </fieldset>
              </.form>
            </section>
            <section :if={@tension} class="admin-panel space-y-5">
              <h2 class="text-xl font-semibold">Pressures & clocks</h2>
              <p id="clock-semantics-notice" class="text-sm text-slate-400">
                Tension-clock endpoints prompt DM adjudication during tick review; neither endpoint automatically settles a situation or fires triggers. Standalone clocks retain legacy full-latch, race and trigger rules. New clocks default to hidden; association never changes visibility.
              </p>
              <div id="tension-clocks" phx-update="stream" class="space-y-4">
                <p id="tension-clocks-empty" class="hidden only:block text-slate-400">
                  No pressures yet.
                </p>
                <article
                  :for={{dom_id, clock} <- @streams.clocks}
                  id={dom_id}
                  class="rounded-xl border border-white/10 p-4 space-y-3"
                >
                  <h3 class="font-semibold">{clock.name} · {clock.filled}/{clock.segments}</h3>
                  <p class="text-xs text-amber-200">
                    {clock.mode} · {clock.visibility} · rate {clock.background_rate} · {if clock.completed,
                      do: "completed",
                      else: "ongoing"}
                  </p>
                  <dl class="space-y-2 whitespace-pre-wrap text-sm text-slate-300">
                    <dt class="font-semibold">Influences</dt><dd id={"clock-influences-#{clock.id}"}>
                      {clock.influences}
                    </dd>
                    <dt class="font-semibold">Empty endpoint</dt><dd id={"clock-empty-#{clock.id}"}>
                      {clock.empty_description}
                    </dd>
                    <dt class="font-semibold">Full endpoint</dt><dd id={"clock-full-#{clock.id}"}>
                      {clock.full_description}
                    </dd>
                  </dl>
                  <button
                    id={"edit-tension-clock-#{clock.id}"}
                    phx-click="edit-clock"
                    phx-value-id={clock.id}
                    disabled={@locked || clock.completed}
                    class="admin-button admin-secondary"
                  >Edit</button>
                  <button
                    id={"detach-clock-#{clock.id}"}
                    phx-click="detach"
                    phx-value-id={clock.id}
                    disabled={@locked || clock.completed}
                    class="admin-button admin-secondary"
                  >Make standalone</button>
                </article>
              </div>
              <h3 class="font-semibold">
                {if @editing_clock, do: "Edit pressure", else: "Add a pressure"}
              </h3>
              <button
                :if={@editing_clock}
                id="new-tension-clock"
                phx-click="new-clock"
                class="admin-button admin-secondary"
              >New clock</button>
              <.form
                for={@clock_form}
                id="tension-clock-form"
                phx-submit="save-clock"
                class="admin-form space-y-4"
              >
                <fieldset disabled={@locked} class="space-y-4">
                  <.input field={@clock_form[:name]} label="Clock name" required class="admin-input" />
                  <.input
                    field={@clock_form[:mode]}
                    label="Descriptive mode"
                    type="select"
                    options={[Countdown: :countdown, "Tug of war": :tug_of_war]}
                    class="admin-input"
                  />
                  <div class="grid grid-cols-2 gap-4">
                    <.input
                      field={@clock_form[:segments]}
                      label="Segments"
                      type="select"
                      options={[4, 6, 8]}
                      class="admin-input"
                    />
                    <.input
                      field={@clock_form[:filled]}
                      label="Current fill"
                      type="number"
                      class="admin-input"
                    />
                    <.input
                      field={@clock_form[:background_rate]}
                      label="Signed background rate"
                      type="number"
                      class="admin-input"
                    />
                    <.input
                      field={@clock_form[:visibility]}
                      label="Clock visibility (independent)"
                      type="select"
                      options={[Hidden: :hidden, "Known (name only)": :known, Public: :public]}
                      class="admin-input"
                    />
                  </div>
                  <.input
                    field={@clock_form[:paused]}
                    type="checkbox"
                    label="Pause background progression"
                    class="admin-checkbox"
                  />
                  <.input
                    field={@clock_form[:influences]}
                    label="Influences (plain text)"
                    type="textarea"
                    class="admin-input"
                  />
                  <.input
                    field={@clock_form[:empty_description]}
                    label="Empty endpoint"
                    type="textarea"
                    class="admin-input"
                  />
                  <.input
                    field={@clock_form[:full_description]}
                    label="Full endpoint"
                    type="textarea"
                    class="admin-input"
                  />
                  <button id="save-tension-clock" class="admin-button" phx-disable-with="Saving…">Save clock</button>
                </fieldset>
              </.form>
              <.form
                for={@association_form}
                id="associate-clock-form"
                phx-submit="associate"
                class="admin-form space-y-4"
              >
                <.input
                  field={@association_form[:clock_id]}
                  type="select"
                  label="Associate an existing standalone clock"
                  prompt="Choose a clock"
                  options={@standalone_options}
                  disabled={@locked}
                  class="admin-input"
                />
                <button id="associate-clock" disabled={@locked} class="admin-button admin-secondary">Associate</button>
              </.form>
              <.link navigate={~p"/clocks"} class="text-sm text-amber-200">Legacy clock rules, resets and racing controls →</.link>
            </section>
          </div>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
