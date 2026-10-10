defmodule AsyncWorldsWeb.DashboardLive do
  use AsyncWorldsWeb, :live_view
  import AsyncWorldsWeb.AdminComponents
  alias AsyncWorlds.{Campaigns, Clocks, Deliveries, Ticks}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(page_title: "Campaign command center") |> refresh()}
  end

  @impl true
  def handle_event("refresh_authorization", _params, socket), do: {:noreply, refresh(socket)}

  def handle_event("open_tick", _params, socket) do
    {:noreply,
     complete(
       socket,
       Ticks.open_tick(campaign_id(socket)),
       "Tick opened. Configure clocks before closing."
     )}
  end

  def handle_event("close_tick", %{"id" => id}, socket) do
    result = with {:ok, id} <- integer(id), do: Ticks.close_tick(campaign_id(socket), id)

    {:noreply,
     complete(socket, result, "Inputs frozen. Resolution is queued; refresh to see progress.")}
  end

  def handle_event("retry_delivery", %{"id" => id, "retry" => params}, socket) do
    result =
      with {:ok, id} <- integer(id), {:ok, generation} <- integer(params["generation"]) do
        Deliveries.retry_delivery(campaign_id(socket), id, generation,
          confirm_ambiguous: params["confirm"] == "true"
        )
      end

    {:noreply, complete(socket, result, "Delivery retry queued. Published state is unchanged.")}
  end

  def handle_event(_, _, socket),
    do: {:noreply, put_flash(socket, :error, "Invalid action. Refresh and try again.")}

  defp complete(socket, {:ok, _}, message), do: socket |> put_flash(:info, message) |> refresh()

  defp complete(socket, {:error, reason}, _),
    do: socket |> put_flash(:error, error_message(reason)) |> refresh()

  defp campaign_id(socket), do: socket.assigns.current_scope.campaign.id

  defp refresh(socket) do
    scope = socket.assigns.current_scope

    {:ok, campaign} =
      Campaigns.authorize_dm(scope.campaign.discord_guild_id, scope.discord_user_id)

    socket = assign(socket, :current_scope, %{scope | campaign: campaign})
    id = campaign.id
    tick = Ticks.active_tick(id)
    clocks = Clocks.list_clocks(id)
    jobs = if tick, do: elem(Ticks.resolution_jobs(id, tick.id), 1), else: []

    deliveries =
      Enum.map(Deliveries.recent_deliveries(id), fn delivery ->
        %{
          id: delivery.id,
          delivery: delivery,
          form:
            params_form(
              %{"generation" => to_string(delivery.generation), "confirm" => "false"},
              [:generation, :confirm], as: :retry, id: "retry-delivery-#{delivery.id}")
        }
      end)

    socket
    |> assign(tick: tick, clock_count: length(clocks))
    |> stream(:clocks, clocks, reset: true)
    |> stream(:audits, Clocks.recent_audits(id), reset: true)
    |> stream(:jobs, jobs, reset: true)
    |> stream(:deliveries, deliveries, reset: true)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.navigation active="dashboard" />
      <section id="dm-dashboard" class="space-y-8">
        <header class="flex flex-wrap items-end justify-between gap-5">
          <div>
            <p class="text-xs uppercase tracking-[0.22em] text-amber-300">
              Your world, one turn at a time
            </p>
            <h1 class="mt-3 text-3xl font-semibold tracking-tight sm:text-5xl">
              Campaign command center
            </h1>
            <p class="mt-3 text-sm text-slate-400">
              Private DM workspace. Players see only the last published state.
            </p>
          </div>
          <button
            id="refresh-authorization"
            phx-click="refresh_authorization"
            class="admin-button admin-secondary"
          ><.icon name="hero-arrow-path" class="size-4" /> Refresh status</button>
        </header>

        <section
          id="campaign-summary"
          class="admin-panel flex flex-wrap items-center justify-between gap-6"
        >
          <div>
            <p class="text-xs uppercase tracking-widest text-slate-400">Last published turn</p>
            <p id="current-tick-number" class="mt-2 text-4xl font-semibold">
              {@current_scope.campaign.current_tick_number}
            </p>
          </div>
          <div>
            <p class="text-xs uppercase tracking-widest text-slate-400">Active tick</p>
            <p id="tick-status" class="mt-2 text-xl font-medium">
              {if @tick,
                do: "Tick #{@tick.number} · #{status_label(@tick.status)}",
                else: "Ready for a new turn"}
            </p>
            <p
              :if={@tick && @tick.status == :resolving}
              id="resolution-pending"
              class="mt-2 text-sm text-amber-200"
            >
              Processing frozen inputs. Refresh to check for a draft or failed job.
            </p>
          </div>
          <div class="flex flex-wrap gap-3">
            <button
              id="open-tick"
              phx-click="open_tick"
              disabled={@tick != nil}
              phx-disable-with="Opening…"
              class="admin-button"
            >Open next tick</button>
            <button
              :if={@tick}
              id="close-tick"
              phx-click="close_tick"
              phx-value-id={@tick.id}
              disabled={@tick.status != :open}
              data-confirm="Close this tick and freeze all world inputs? Clock management will lock until publication."
              phx-disable-with="Closing…"
              class="admin-button admin-secondary"
            >Close & resolve</button>
            <.link
              :if={@tick && @tick.status == :in_review}
              id="review-tick"
              navigate={~p"/ticks/#{@tick.id}/review"}
              class="admin-button"
            >Review draft <.icon name="hero-arrow-right" class="size-4" /></.link>
          </div>
        </section>

        <div class="grid gap-8 lg:grid-cols-[1.2fr_1fr]">
          <section class="admin-panel">
            <div class="mb-5 flex items-center justify-between">
              <h2 class="text-lg font-semibold">
                Live clocks <span class="text-sm text-slate-500">{@clock_count}</span>
              </h2><.link
                id="manage-clocks"
                navigate={~p"/clocks"}
                class="text-sm text-amber-300 hover:text-amber-100"
              >Manage clocks</.link>
            </div>
            <div id="dashboard-clocks" phx-update="stream" class="space-y-3">
              <p id="dashboard-clocks-empty" class="hidden only:block text-sm text-slate-400">
                No clocks yet. Create your first world clock.
              </p>
              <article
                :for={{dom_id, clock} <- @streams.clocks}
                id={dom_id}
                class="rounded-xl border border-white/10 p-4"
              >
                <div class="flex justify-between gap-4">
                  <h3 class="font-medium">{clock.name}</h3><span class="text-xs text-slate-400">{clock.visibility} · {if clock.completed,
                    do: "completed",
                    else: if(clock.paused, do: "paused", else: "running")}</span>
                </div>
                <div class="mt-3 flex items-center gap-4">
                  <progress
                    aria-label={"#{clock.name} fill"}
                    value={clock.filled}
                    max={clock.segments}
                    class="h-2 w-full accent-amber-300"
                  ></progress><span class="whitespace-nowrap text-sm tabular-nums text-amber-200">{clock.filled}/{clock.segments}</span>
                </div>
              </article>
            </div>
          </section>
          <section class="admin-panel">
            <h2 class="mb-5 text-lg font-semibold">Recent clock changes</h2>
            <div id="recent-fills" phx-update="stream" class="space-y-3">
              <p id="recent-fills-empty" class="hidden only:block text-sm text-slate-400">
                No clock changes recorded.
              </p>
              <article
                :for={{dom_id, audit} <- @streams.audits}
                id={dom_id}
                class="border-b border-white/10 pb-3 text-sm"
              >
                <p>
                  Clock #{audit.clock_id} · {audit.operation}
                  <span class="text-amber-200">{audit.before["filled"] || 0} → {audit.after["filled"]}</span>
                </p>
                <p class="mt-1 break-all text-xs text-slate-500">{audit.source}</p>
              </article>
            </div>
          </section>
        </div>

        <section class="admin-panel">
          <h2 class="mb-2 text-lg font-semibold">Resolution jobs</h2><p class="mb-5 text-sm text-slate-400">
            Failed processing keeps the tick locked. Investigate discarded or cancelled jobs before retrying via authorized operations.
          </p>
          <div id="resolution-jobs" phx-update="stream" class="space-y-2">
            <p id="resolution-jobs-empty" class="hidden only:block text-sm text-slate-400">
              No active resolution jobs.
            </p>
            <p
              :for={{dom_id, job} <- @streams.jobs}
              id={dom_id}
              class="rounded-xl bg-white/5 p-3 text-sm"
            >
              Job #{job.id} ·
              <span class={job.state in ["retryable", "discarded", "cancelled"] && "text-rose-300"}>{job.state}</span>
              · attempts {job.attempt}/{job.max_attempts}
            </p>
          </div>
        </section>

        <section class="admin-panel">
          <h2 class="text-lg font-semibold">
            Outgoing deliveries <span class="text-xs text-slate-500">Latest 50</span>
          </h2><p class="mb-5 mt-2 text-sm text-slate-400">
            Retry a specific failed send, never republish. Ambiguous sends may already exist in Discord.
          </p>
          <div id="delivery-list" phx-update="stream" class="space-y-4">
            <p id="delivery-list-empty" class="hidden only:block text-sm text-slate-400">
              Nothing queued yet.
            </p>
            <article
              :for={{dom_id, item} <- @streams.deliveries}
              id={dom_id}
              class="rounded-xl border border-white/10 p-4"
            >
              <div class="flex flex-wrap items-center justify-between gap-4">
                <div>
                  <p class="font-medium">
                    Tick #{item.delivery.tick_id} · {item.delivery.kind} · {item.delivery.status}
                  </p><p class="mt-1 text-xs text-slate-400">
                    Recipient {item.delivery.recipient_id} · attempts {item.delivery.attempts}
                    <span :if={item.delivery.last_error}>· {item.delivery.last_error}</span>
                  </p>
                </div>
                <.form
                  :if={item.delivery.status in [:failed, :ambiguous]}
                  for={item.form}
                  id={"retry-delivery-#{item.id}"}
                  phx-submit="retry_delivery"
                  phx-value-id={item.id}
                  class="admin-form space-y-3"
                >
                  <.input field={item.form[:generation]} type="hidden" />
                  <.input
                    :if={item.delivery.status == :ambiguous}
                    field={item.form[:confirm]}
                    type="checkbox"
                    label="I checked Discord and accept a possible duplicate"
                    class="admin-checkbox"
                  />
                  <button
                    id={"retry-delivery-button-#{item.id}"}
                    class="admin-button admin-secondary"
                    phx-disable-with="Queueing…"
                  >Retry this delivery</button>
                </.form>
              </div>
            </article>
          </div>
        </section>
      </section>
    </Layouts.app>
    """
  end

  defp status_label(:in_review), do: "in review"
  defp status_label(status), do: to_string(status)
end
