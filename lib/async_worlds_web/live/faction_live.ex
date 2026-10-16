defmodule AsyncWorldsWeb.FactionLive do
  use AsyncWorldsWeb, :live_view
  import AsyncWorldsWeb.AdminComponents

  alias AsyncWorldsWeb.MembershipPanel
  alias AsyncWorlds.Factions
  alias AsyncWorlds.Factions.Faction

  @impl true
  def mount(_, _, socket) do
    {:ok, socket |> assign(page_title: "Factions") |> clear_form() |> refresh()}
  end

  @impl true
  def handle_event("new", _, socket) do
    case Factions.change_faction(scope(socket)) do
      {:ok, changeset} -> {:noreply, socket |> clear_form() |> assign(form: to_form(changeset))}
      {:error, reason} -> {:noreply, failure(socket, reason)}
    end
  end

  def handle_event("edit", %{"id" => id}, socket) do
    case Factions.change_faction(scope(socket), id) do
      {:ok, changeset} ->
        {:noreply,
         socket |> assign(editing: changeset.data, form: to_form(changeset)) |> load_memberships()}

      {:error, reason} ->
        {:noreply, socket |> clear_form() |> failure(reason)}
    end
  end

  def handle_event("save", %{"faction" => params}, socket) do
    attrs = Map.take(params, ["name", "description"])

    result =
      if socket.assigns.editing,
        do: Factions.update_faction(scope(socket), socket.assigns.editing.id, attrs),
        else: Factions.create_faction(scope(socket), attrs)

    case result do
      {:ok, faction} ->
        {:noreply,
         socket
         |> assign(editing: faction, form: to_form(Faction.changeset(faction, %{})))
         |> load_memberships()
         |> refresh()
         |> put_flash(:info, "Faction saved.")}

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
        do: Factions.delete_faction(scope(socket), socket.assigns.editing.id),
        else: {:error, :not_found}

    case result do
      {:ok, _} ->
        {:noreply, socket |> clear_form() |> refresh() |> put_flash(:info, "Faction deleted.")}

      {:error, reason} ->
        {:noreply, failure(socket, reason)}
    end
  end

  def handle_event(event, params, socket)
      when event in ["membership_join", "membership_role", "membership_leave"] do
    case MembershipPanel.handle(socket, event, params) do
      {:ok, socket} -> {:noreply, socket}
      {:error, reason} -> {:noreply, failure(socket, reason)}
    end
  end

  def handle_event(_, _, socket), do: {:noreply, failure(socket, :not_found)}

  defp load_memberships(socket) do
    case MembershipPanel.load(socket, :faction, socket.assigns.editing) do
      {:ok, socket} -> socket
      {:error, reason} -> failure(socket, reason)
    end
  end

  defp scope(socket), do: socket.assigns.current_scope

  defp clear_form(socket) do
    socket
    |> MembershipPanel.reset()
    |> assign(editing: nil, form: to_form(Faction.changeset(%Faction{}, %{})))
  end

  defp refresh(%{redirected: redirect} = socket) when not is_nil(redirect), do: socket

  defp refresh(socket) do
    case Factions.list_factions(scope(socket)) do
      {:ok, factions} -> stream(socket, :factions, factions, reset: true)
      {:error, reason} -> socket |> stream(:factions, [], reset: true) |> failure(reason)
    end
  end

  defp failure(socket, reason)
       when reason in [:unauthorized, :stale_campaign, :invalid_scope, :invalid_id] do
    cleared = socket |> clear_form() |> stream(:factions, [], reset: true)
    if cleared.redirected, do: cleared, else: redirect(cleared, to: ~p"/login")
  end

  defp failure(socket, :not_found),
    do:
      socket
      |> clear_form()
      |> put_flash(:error, "Faction not found. Reopen the list and try again.")

  defp failure(socket, :faction_has_memberships),
    do: put_flash(socket, :error, "Remove this faction's current memberships before deleting it.")

  defp failure(socket, reason), do: put_flash(socket, :error, error_message(reason))

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.navigation active="factions" />
      <section id="faction-management" class="space-y-7">
        <header>
          <p class="text-xs uppercase tracking-widest text-amber-300">Campaign powers</p>
          <h1 class="mt-2 text-4xl font-semibold tracking-tight">Factions</h1>
          <p class="mt-3 text-sm text-slate-400">
            Keep track of the groups that shape your campaign. Names and descriptions are readable by all server members through /faction. Factions have no tick effects.
          </p>
        </header>
        <div class="grid gap-7 lg:grid-cols-2">
          <section class="admin-panel space-y-5">
            <div class="flex items-center justify-between gap-4">
              <h2 class="text-xl font-semibold">
                {if @editing, do: "Edit faction", else: "Create a faction"}
              </h2>
              <button id="new-faction" phx-click="new" class="admin-button admin-secondary">New</button>
            </div>
            <.form for={@form} id="faction-form" phx-submit="save" class="admin-form space-y-4">
              <.input
                field={@form[:name]}
                label="Faction name"
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
                <button id="save-faction" class="admin-button" phx-disable-with="Saving…">Save faction</button>
                <button
                  :if={@editing}
                  id="delete-faction"
                  type="button"
                  phx-click="delete"
                  data-confirm={"Permanently delete #{@editing.name}? This cannot be undone."}
                  phx-disable-with="Deleting…"
                  class="admin-button admin-secondary text-rose-300 hover:text-rose-100 transition"
                >Delete faction</button>
              </div>
            </.form>
            <MembershipPanel.panel
              :if={@editing}
              type={:faction}
              form={@membership_form}
              options={@membership_options}
              memberships={@streams.memberships}
              error={@membership_error}
              target={@membership_target}
            />
          </section>
          <section class="admin-panel">
            <h2 class="mb-5 text-xl font-semibold">Campaign factions</h2>
            <div id="managed-factions" phx-update="stream" class="space-y-3">
              <p id="factions-empty" class="hidden only:block text-sm text-slate-400">
                Create the first faction to get started.
              </p>
              <article
                :for={{dom_id, faction} <- @streams.factions}
                id={dom_id}
                class="rounded-xl border border-white/10 p-4 flex items-start justify-between gap-4"
              >
                <div class="min-w-0">
                  <h3 class="font-semibold break-words">{faction.name}</h3>
                  <p
                    :if={faction.description}
                    class="mt-2 text-sm text-slate-400 whitespace-pre-wrap break-words"
                  >
                    {faction.description}
                  </p>
                </div>
                <button
                  id={"edit-faction-#{faction.id}"}
                  phx-click="edit"
                  phx-value-id={faction.id}
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
