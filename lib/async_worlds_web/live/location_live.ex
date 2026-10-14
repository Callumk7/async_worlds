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
      {:ok, changeset} -> {:noreply, assign(socket, editing: nil, form: to_form(changeset))}
      {:error, reason} -> {:noreply, failure(socket, reason)}
    end
  end

  def handle_event("edit", %{"id" => id}, socket) do
    case Locations.change_location(scope(socket), id) do
      {:ok, changeset} ->
        {:noreply, assign(socket, editing: changeset.data, form: to_form(changeset))}

      {:error, reason} ->
        {:noreply, socket |> clear_form() |> failure(reason)}
    end
  end

  def handle_event("save", %{"location" => params}, socket) do
    attrs = Map.take(params, ["name", "description"])

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
    assign(socket, editing: nil, form: to_form(Location.changeset(%Location{}, %{})))
  end

  defp refresh(%{redirected: redirect} = socket) when not is_nil(redirect), do: socket

  defp refresh(socket) do
    case Locations.list_locations(scope(socket)) do
      {:ok, locations} -> stream(socket, :locations, locations, reset: true)
      {:error, reason} -> socket |> stream(:locations, [], reset: true) |> failure(reason)
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
            Keep track of the places that shape your campaign. Names and descriptions are readable by all server members through /location. Locations have no tick effects.
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
          </section>
          <section class="admin-panel">
            <h2 class="mb-5 text-xl font-semibold">Campaign locations</h2>
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
