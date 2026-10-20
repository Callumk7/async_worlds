defmodule AsyncWorldsWeb.EventChronicleLive do
  use AsyncWorldsWeb, :live_view
  import AsyncWorldsWeb.AdminComponents
  alias AsyncWorlds.Ticks.Chronicle

  @impl true
  def mount(_, _, socket), do: {:ok, assign(socket, page_title: "Event chronicle", detail: nil)}

  @impl true
  def handle_params(params, _, socket) do
    scope = socket.assigns.current_scope

    filters =
      Map.take(params, ~w(page tick entity entity_id through))
      |> Map.reject(fn {_, v} -> v == "" end)

    filters =
      if socket.assigns.live_action == :tension,
        do: Map.merge(filters, %{"entity" => "tension", "entity_id" => params["id"]}),
        else: filters

    result =
      if socket.assigns.live_action == :show do
        Chronicle.fetch(
          scope.campaign.discord_guild_id,
          scope.discord_user_id,
          :dm,
          params["tick_id"],
          params["event"],
          Map.delete(filters, "page")
        )
      else
        Chronicle.list(scope.campaign.discord_guild_id, scope.discord_user_id, :dm, filters)
      end

    socket =
      case result do
        {:ok, %{items: items} = listing} ->
          filters =
            if listing.through > 0,
              do: Map.put(filters, "through", listing.through),
              else: filters

          socket
          |> assign(
            detail: nil,
            listing: Map.delete(listing, :items),
            filters: filters,
            form: to_form(Map.drop(filters, ~w(page through)), as: :filter)
          )
          |> stream(:events, Enum.map(items, &Map.put(&1, :id, &1["id"])), reset: true)

        {:ok, detail} ->
          assign(socket, detail: detail, filters: filters)

        _ ->
          socket
          |> put_flash(:error, "Published history unavailable.")
          |> push_navigate(to: ~p"/ticks/history")
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("filter", %{"filter" => params}, socket) do
    filters = Map.take(params, ~w(tick entity entity_id)) |> Map.reject(fn {_, v} -> v == "" end)
    {:noreply, push_patch(socket, to: ~p"/events?#{filters}")}
  end

  defp event_path(e, filters),
    do: ~p"/events/#{e["tick_id"]}?#{Map.put(Map.delete(filters, "page"), "event", e["key"])}"

  defp reference_path(r), do: ~p"/events?#{%{"entity" => r["entity"], "entity_id" => r["id"]}}"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.navigation active="history" />
      <section id="event-chronicle" class="space-y-7">
        <header class="space-y-3">
          <p class="text-xs uppercase tracking-widest text-amber-300">
            Private DM view · established history
          </p>
          <h1 class="text-4xl font-semibold tracking-tight">The world remembers</h1>
          <p class="text-sm text-slate-400">
            One account, connected across places, people and unfolding situations.
          </p>
          <.link
            id="chronicle-archive"
            navigate={~p"/ticks/history"}
            class="text-sm text-amber-200 hover:underline"
          >Tick archive, routine pressures and mechanical records</.link>
        </header>
        <%= if @detail do %>
          <article id="event-detail" class="admin-panel space-y-6">
            <div class="text-xs text-amber-300">
              Tick {@detail.event["tick_number"]} · {@detail.event["kind"]} · {@detail.event[
                "audience"
              ]}
            </div>
            <h2 class="text-3xl font-semibold">{@detail.event["title"]}</h2>
            <p id="event-narrative" class="whitespace-pre-wrap leading-relaxed text-slate-200">
              {@detail.event["text"]}
            </p>
            <div id="event-references" class="flex flex-wrap gap-2">
              <.link
                :for={r <- @detail.event["references"]}
                navigate={reference_path(r)}
                class="rounded-lg border border-white/10 px-3 py-2 text-sm text-amber-200 transition hover:border-amber-300/50"
              >{r["entity"]} · {r["name"]}</.link>
            </div>
            <section
              :if={@detail.event["follow_on"] != []}
              id="event-follow-on"
              class="border-l-2 border-amber-300/40 pl-4"
            >
              <h3 class="text-sm text-slate-400">What it led to</h3>
              <.link
                :for={r <- @detail.event["follow_on"]}
                navigate={reference_path(r)}
                class="mt-2 block text-amber-200 hover:underline"
              >{r["name"]} <.icon name="hero-arrow-right" class="size-4" /></.link>
            </section>
            <details id="event-mechanics" class="rounded-lg border border-white/10 p-4">
              <summary class="cursor-pointer text-sm text-slate-400 hover:text-amber-200">
                Inspect saved changes and adjudication
              </summary>
              <p class="mt-4 text-xs text-slate-400">
                DM {@detail.event["actor_id"]} · {@detail.event["reason"]}
              </p>
              <div :for={change <- @detail.event["changes"]} class="mt-4 space-y-2">
                <h3 class="text-sm font-semibold">{change["entity"]} · {change["after"]["name"]}</h3>
                <pre class="overflow-x-auto whitespace-pre-wrap text-xs text-slate-400">{Jason.encode!(Map.take(change, ~w(before after)), pretty: true)}</pre>
              </div>
            </details>
            <.link
              id="event-tick"
              navigate={~p"/ticks/#{@detail.event["tick_id"]}/history"}
              class="text-sm text-amber-200 hover:underline"
            >Read this tick, including routine changes</.link>
          </article>
          <nav id="event-navigation" class="flex flex-wrap justify-between gap-4">
            <.link
              :if={@detail.earlier}
              id="event-earlier"
              navigate={event_path(@detail.earlier, @filters)}
              class="admin-button admin-secondary"
            >Earlier · {@detail.earlier["title"]}</.link>
            <.link
              id="event-back"
              navigate={~p"/events?#{@filters}"}
              class="admin-button admin-secondary"
            >Back to chronicle</.link>
            <.link
              :if={@detail.later}
              id="event-later"
              navigate={event_path(@detail.later, @filters)}
              class="admin-button admin-secondary"
            >Later · {@detail.later["title"]}</.link>
          </nav>
        <% else %>
          <.form
            for={@form}
            id="chronicle-filters"
            phx-submit="filter"
            class="admin-panel grid gap-4 sm:grid-cols-4"
          >
            <.input field={@form[:tick]} label="Tick ID" class="admin-input" />
            <.input
              field={@form[:entity]}
              label="Reference type"
              type="select"
              options={[
                "All entities": "",
                Tension: "tension",
                Location: "location",
                Character: "character",
                Faction: "faction"
              ]}
              class="admin-input"
            />
            <.input field={@form[:entity_id]} label="Entity ID" class="admin-input" />
            <button id="chronicle-filter" class="admin-button self-end">Explore history</button>
          </.form>
          <div
            id={if @live_action == :tension, do: "tension-events", else: "chronicle-events"}
            phx-update="stream"
            class="space-y-5"
          >
            <p id="chronicle-empty" class="hidden only:block admin-panel text-slate-400">
              No published Events on this page. Drafts are not history.
            </p>
            <article
              :for={{dom_id, e} <- @streams.events}
              id={dom_id}
              class="admin-panel space-y-3 transition hover:border-amber-300/30"
            >
              <p class="text-xs text-slate-400">
                Tick {e["tick_number"]} · {e["kind"]} · {e["audience"]}
              </p>
              <h2 class="text-2xl font-semibold">
                <.link navigate={event_path(e, @filters)} class="text-amber-100 hover:text-amber-200">{e[
                  "title"
                ]}</.link>
              </h2>
              <p class="whitespace-pre-wrap text-sm leading-relaxed text-slate-300">{e["text"]}</p>
              <.link
                id={"read-event-#{e["tick_id"]}-#{e["key"]}"}
                navigate={event_path(e, @filters)}
                class="text-sm text-amber-200 hover:underline"
              >Read account and connections <.icon name="hero-arrow-right" class="size-4" /></.link>
            </article>
          </div>
          <nav class="flex items-center gap-4 text-sm">
            <.link
              :if={@listing.page > 1}
              id="chronicle-previous"
              patch={~p"/events?#{Map.put(@filters, "page", @listing.page - 1)}"}
              class="admin-button admin-secondary"
            >Newer</.link>
            <span class="text-slate-400">Page {@listing.page}</span>
            <.link
              :if={@listing.more?}
              id="chronicle-next"
              patch={~p"/events?#{Map.put(@filters, "page", @listing.page + 1)}"}
              class="admin-button admin-secondary"
            >Older</.link>
          </nav>
        <% end %>
      </section>
    </Layouts.app>
    """
  end
end
