defmodule AsyncWorldsWeb.TensionHistoryLive do
  use AsyncWorldsWeb, :live_view
  import AsyncWorldsWeb.AdminComponents

  @impl true
  def mount(_, _, socket), do: {:ok, assign(socket, page_title: "Tension chronicle")}

  @impl true
  def handle_params(%{"id" => id}, _, socket) do
    scope = socket.assigns.current_scope

    case AsyncWorlds.Ticks.History.tension(
           scope.campaign.discord_guild_id,
           scope.discord_user_id,
           id
         ) do
      {:ok, events} ->
        events = Enum.map(events, &Map.put(&1, :id, "#{&1["tick_id"]}-#{&1["id"]}"))
        {:noreply, stream(socket, :events, events, reset: true)}

      _ ->
        {:noreply,
         socket
         |> put_flash(:error, "History unavailable.")
         |> push_navigate(to: ~p"/ticks/history")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.navigation active="history" />
      <section id="tension-chronicle" class="space-y-6">
        <header>
          <p class="text-xs uppercase tracking-widest text-amber-300">Private DM chronicle</p>
          <h1 class="mt-3 text-4xl font-semibold">An unfolding situation</h1>
          <p class="mt-3 text-sm text-slate-400">
            Established Events and immutable context, never draft intentions.
          </p>
        </header>
        <div id="tension-events" phx-update="stream" class="space-y-5">
          <p id="tension-events-empty" class="hidden only:block admin-panel">
            No published Events for this Tension.
          </p>
          <article :for={{dom_id, event} <- @streams.events} id={dom_id} class="admin-panel space-y-3">
            <p class="text-xs text-amber-300">Tick {event["tick_number"]} · {event["kind"]}</p>
            <h2 class="text-2xl font-semibold">{event["title"]}</h2>
            <p class="whitespace-pre-wrap">{event["text"]}</p>
            <p class="text-xs text-slate-400">
              Adjudicated by DM {event["actor_id"]} · {event["reason"]}
            </p>
            <.link
              navigate={~p"/ticks/#{event["tick_id"]}/history"}
              class="text-sm text-amber-200 hover:underline"
            >Read tick and saved before/after context</.link>
          </article>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
