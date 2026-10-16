defmodule AsyncWorldsWeb.LocationLive do
  use AsyncWorldsWeb, :live_view
  import AsyncWorldsWeb.AdminComponents

  alias AsyncWorlds.Locations
  alias AsyncWorlds.Locations.Location

  @impl true
  def mount(_, _, socket) do
    {:ok, socket |> assign(page_title: "Locations") |> clear_form() |> refresh()}
  end

  @impl true
  def handle_event("new", _, socket) do
    case Locations.change_location(scope(socket)) do
      {:ok, _changeset} -> {:noreply, socket |> clear_form() |> refresh()}
      {:error, reason} -> {:noreply, failure(socket, reason)}
    end
  end

  def handle_event("edit", %{"id" => id}, socket) do
    case Locations.change_location(scope(socket), id) do
      {:ok, changeset} ->
        {:noreply,
         socket
         |> assign(editing: changeset.data, form: to_form(changeset))
         |> refresh()}

      {:error, reason} ->
        {:noreply, socket |> clear_form() |> failure(reason)}
    end
  end

  def handle_event("save", %{"location" => params}, socket) do
    attrs = Map.take(params, ["name", "description", "kind"])

    result =
      if socket.assigns.editing,
        do: Locations.update_location(scope(socket), socket.assigns.editing.id, attrs),
        else: Locations.create_location(scope(socket), attrs)

    case result do
      {:ok, location} ->
        {:noreply,
         socket
         |> assign(editing: location, form: to_form(Location.changeset(location, %{})))
         |> refresh()
         |> put_flash(:info, "Location saved.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}

      {:error, reason} ->
        {:noreply, failure(socket, reason)}
    end
  end

  def handle_event("set-parent", %{"containment" => %{"parent_id" => parent_id}}, socket) do
    result =
      if socket.assigns.editing do
        Locations.set_parent(
          scope(socket),
          socket.assigns.editing.id,
          if(parent_id == "", do: nil, else: parent_id)
        )
      else
        {:error, :not_found}
      end

    case result do
      {:ok, location} ->
        {:noreply,
         socket
         |> assign(:editing, location)
         |> refresh()
         |> put_flash(:info, "Location parent saved.")}

      {:error, :not_found} when not is_nil(socket.assigns.editing) ->
        case Locations.get_location(scope(socket), socket.assigns.editing.id) do
          {:ok, _} ->
            {:noreply,
             socket
             |> refresh()
             |> put_flash(
               :error,
               "Parent unavailable. Choose a location from this campaign or select No parent."
             )}

          {:error, reason} ->
            {:noreply, failure(socket, reason)}
        end

      {:error, reason} ->
        {:noreply, failure(socket, reason)}
    end
  end

  def handle_event("delete", _, socket) do
    # Delete only the server-selected record, never a submitted target ID.
    result =
      if socket.assigns.editing,
        do: Locations.delete_location(scope(socket), socket.assigns.editing.id),
        else: {:error, :not_found}

    case result do
      {:ok, _} ->
        {:noreply, socket |> clear_form() |> refresh() |> put_flash(:info, "Location deleted.")}

      {:error, reason} ->
        {:noreply, failure(socket, reason)}
    end
  end

  def handle_event(_, _, socket), do: {:noreply, failure(socket, :not_found)}

  defp scope(socket), do: socket.assigns.current_scope

  defp clear_form(socket) do
    socket
    |> assign(
      editing: nil,
      form: to_form(Location.changeset(%Location{}, %{})),
      parent_form: to_form(%{"parent_id" => ""}, as: :containment),
      parent_options: []
    )
    |> stream(:location_breadcrumbs, [], reset: true)
    |> stream(:location_children, [], reset: true)
  end

  defp refresh(%{redirected: redirect} = socket) when not is_nil(redirect), do: socket

  defp refresh(socket) do
    case Locations.list_locations(scope(socket)) do
      {:ok, locations} ->
        options =
          locations
          |> Enum.reject(&(socket.assigns.editing && &1.id == socket.assigns.editing.id))
          |> Enum.map(&{"#{&1.name} (##{&1.id})", &1.id})

        socket
        |> stream(:locations, locations, reset: true)
        |> assign(:parent_options, options)
        |> refresh_navigation()

      {:error, reason} ->
        socket |> stream(:locations, [], reset: true) |> failure(reason)
    end
  end

  defp refresh_navigation(socket) do
    editing = socket.assigns.editing

    with {:ok, children} <- Locations.list_children(scope(socket), editing && editing.id) do
      socket =
        socket
        |> stream(:location_children, children, reset: true)
        |> assign(
          :parent_form,
          to_form(%{"parent_id" => (editing && editing.parent_id) || ""}, as: :containment)
        )

      if editing do
        case Locations.breadcrumbs(scope(socket), editing.id) do
          {:ok, path} ->
            stream(socket, :location_breadcrumbs, path, reset: true)

          {:error, reason} ->
            socket |> stream(:location_breadcrumbs, [], reset: true) |> failure(reason)
        end
      else
        stream(socket, :location_breadcrumbs, [], reset: true)
      end
    else
      {:error, reason} -> failure(socket, reason)
    end
  end

  defp failure(socket, reason)
       when reason in [:unauthorized, :stale_campaign, :invalid_scope, :invalid_id] do
    cleared = socket |> clear_form() |> stream(:locations, [], reset: true)
    if cleared.redirected, do: cleared, else: redirect(cleared, to: ~p"/login")
  end

  defp failure(socket, :not_found),
    do:
      socket
      |> clear_form()
      |> put_flash(:error, "Location not found. Reopen the list and try again.")

  defp failure(socket, :location_cycle),
    do:
      put_flash(
        socket,
        :error,
        "A location cannot be inside itself or one of its descendants. Choose another parent or No parent."
      )

  defp failure(socket, :hierarchy_too_deep),
    do:
      put_flash(
        socket,
        :error,
        "This hierarchy exceeds the 100-location navigation limit. Clear a parent link to shorten it."
      )

  defp failure(socket, :location_linked),
    do:
      put_flash(
        socket,
        :error,
        "Clear this location's parent and child links before deleting it."
      )

  defp failure(socket, reason), do: put_flash(socket, :error, error_message(reason))

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.navigation active="locations" />
      <section id="location-management" class="space-y-7">
        <header>
          <p class="text-xs uppercase tracking-widest text-amber-300">Campaign atlas</p>
          <h1 class="mt-2 text-4xl font-semibold tracking-tight">Locations</h1>
          <p class="mt-3 text-sm text-slate-400">
            Keep track of the places that shape your campaign. Names and descriptions are readable by all server members through /location. Kind and hierarchy are DM-only and have no gameplay effects.
          </p>
        </header>
        <div class="grid gap-7 lg:grid-cols-2">
          <section class="admin-panel space-y-5">
            <div class="flex items-center justify-between gap-4">
              <h2 class="text-xl font-semibold">
                {if @editing, do: "Edit location", else: "Create a location"}
              </h2>
              <button id="new-location" phx-click="new" class="admin-button admin-secondary">New</button>
            </div>
            <.form for={@form} id="location-form" phx-submit="save" class="admin-form space-y-4">
              <.input
                field={@form[:name]}
                label="Location name"
                required
                maxlength="200"
                class="admin-input"
              />
              <.input
                field={@form[:description]}
                type="textarea"
                label="Description (optional)"
                class="admin-input"
              />
              <.input
                field={@form[:kind]}
                label="Kind (optional, DM-only)"
                placeholder="e.g. district, wilderness, tavern"
                class="admin-input"
              />
              <div class="flex flex-wrap gap-3">
                <button id="save-location" class="admin-button" phx-disable-with="Saving…">Save location</button>
                <button
                  :if={@editing}
                  id="delete-location"
                  type="button"
                  phx-click="delete"
                  data-confirm={"Permanently delete #{@editing.name}? This cannot be undone."}
                  phx-disable-with="Deleting…"
                  class="admin-button admin-secondary text-rose-300 hover:text-rose-100 transition"
                >Delete location</button>
              </div>
            </.form>
            <section
              :if={@editing}
              id="location-hierarchy"
              class="space-y-4 border-t border-white/10 pt-5"
            >
              <div>
                <h3 class="text-lg font-semibold">Place in the world</h3>
                <p class="mt-1 text-sm text-slate-400">
                  Parent changes save separately and retain history with the current open or next tick.
                </p>
              </div>
              <nav aria-label="Location breadcrumbs">
                <div
                  id="location-breadcrumbs"
                  phx-update="stream"
                  class="flex flex-wrap items-center gap-2"
                >
                  <span :for={{dom_id, location} <- @streams.location_breadcrumbs} id={dom_id}>
                    <button
                      id={"breadcrumb-location-#{location.id}"}
                      type="button"
                      phx-click="edit"
                      phx-value-id={location.id}
                      aria-current={location.id == @editing.id && "location"}
                      class="inline-flex items-center gap-1 rounded-lg px-2 py-1 text-sm text-amber-200 transition hover:bg-white/5 focus-visible:outline-2 focus-visible:outline-amber-300"
                    >
                      <.icon name="hero-chevron-right" class="size-3 shrink-0" />
                      {location.name}
                    </button>
                  </span>
                </div>
              </nav>
              <.form
                for={@parent_form}
                id="location-parent-form"
                phx-submit="set-parent"
                class="space-y-3"
              >
                <.input
                  field={@parent_form[:parent_id]}
                  type="select"
                  label="Parent location (DM-only)"
                  options={[{"No parent (root location)", ""} | @parent_options]}
                  class="admin-input"
                />
                <button
                  id="save-location-parent"
                  class="admin-button admin-secondary"
                  phx-disable-with="Saving parent…"
                >
                  Save parent
                </button>
              </.form>
            </section>
            <p :if={!@editing} id="location-parent-hint" class="text-sm text-slate-400">
              Save a location first, then choose its parent. Leave it without a parent to keep it at the root.
            </p>
          </section>
          <section class="admin-panel space-y-6">
            <section aria-labelledby="location-children-heading" class="space-y-3">
              <div class="flex items-center justify-between gap-3">
                <h2 id="location-children-heading" class="text-lg font-semibold">
                  {if @editing, do: "Inside #{@editing.name}", else: "Root locations"}
                </h2>
                <button
                  :if={@editing}
                  id="location-roots"
                  type="button"
                  phx-click="new"
                  class="admin-button admin-secondary"
                >
                  <.icon name="hero-home" class="size-4" /> Roots
                </button>
              </div>
              <div id="location-children" phx-update="stream" class="space-y-2">
                <p id="location-children-empty" class="hidden only:block text-sm text-slate-400">
                  {if @editing, do: "No child locations yet.", else: "No root locations yet."}
                </p>
                <div :for={{dom_id, location} <- @streams.location_children} id={dom_id}>
                  <button
                    id={"child-location-#{location.id}"}
                    type="button"
                    phx-click="edit"
                    phx-value-id={location.id}
                    class="flex w-full items-center justify-between gap-3 rounded-xl border border-white/10 px-4 py-3 text-left text-sm transition hover:border-amber-300/30 hover:bg-white/5 focus-visible:outline-2 focus-visible:outline-amber-300"
                  >
                    <span class="min-w-0 break-words">{location.name}</span>
                    <.icon name="hero-chevron-right" class="size-4 shrink-0 text-amber-200" />
                  </button>
                </div>
              </div>
            </section>
            <h2 class="text-xl font-semibold">All campaign locations</h2>
            <div id="managed-locations" phx-update="stream" class="space-y-3">
              <p id="locations-empty" class="hidden only:block text-sm text-slate-400">
                Create the first location to get started.
              </p>
              <article
                :for={{dom_id, location} <- @streams.locations}
                id={dom_id}
                class="rounded-xl border border-white/10 p-4 flex items-start justify-between gap-4"
              >
                <div class="min-w-0">
                  <h3 class="font-semibold break-words">{location.name}</h3>
                  <p
                    :if={location.kind}
                    id={"location-kind-#{location.id}"}
                    class="mt-1 text-xs uppercase tracking-wide text-amber-200/80 break-words"
                  >
                    {location.kind}
                  </p>
                  <p
                    :if={location.description}
                    class="mt-2 text-sm text-slate-400 whitespace-pre-wrap break-words"
                  >
                    {location.description}
                  </p>
                </div>
                <button
                  id={"edit-location-#{location.id}"}
                  phx-click="edit"
                  phx-value-id={location.id}
                  class="admin-button admin-secondary shrink-0"
                >Edit</button>
              </article>
            </div>
          </section>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
