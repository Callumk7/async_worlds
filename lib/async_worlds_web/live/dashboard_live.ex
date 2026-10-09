defmodule AsyncWorldsWeb.DashboardLive do
  use AsyncWorldsWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Campaign command center")}
  end

  @impl true
  def handle_event("refresh_authorization", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info(:session_revoked, socket), do: {:noreply, redirect(socket, to: ~p"/login")}

  def handle_info(:session_expired, socket), do: {:noreply, redirect(socket, to: ~p"/login")}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <section id="dm-dashboard" class="grid gap-8 lg:grid-cols-[1.35fr_0.65fr]">
        <div class="rounded-3xl border border-white/10 bg-white/[0.04] p-7 shadow-2xl shadow-black/20 sm:p-10">
          <div class="mb-10 flex items-center gap-3 text-xs font-semibold uppercase tracking-[0.24em] text-amber-300">
            <span class="size-2 rounded-full bg-emerald-400 shadow-[0_0_18px_rgba(52,211,153,0.8)]"></span>
            DM access verified
          </div>
          <p class="max-w-xl text-sm leading-6 text-slate-400">Your campaign workspace</p>
          <h1 class="mt-3 max-w-2xl text-4xl font-semibold tracking-tight text-white sm:text-6xl">
            The world is waiting for its next turn.
          </h1>
          <p class="mt-6 max-w-xl text-base leading-7 text-slate-300">
            This secure shell is ready. Clock and tick controls will arrive in their dedicated milestones.
          </p>
          <button
            id="refresh-authorization"
            phx-click="refresh_authorization"
            class="mt-9 inline-flex items-center gap-2 rounded-full border border-white/15 bg-white/10 px-5 py-3 text-sm font-semibold text-white transition hover:-translate-y-0.5 hover:border-amber-300/60 hover:bg-white/15 focus:outline-none focus:ring-2 focus:ring-amber-300"
          >
            <.icon name="hero-shield-check" class="size-5 text-amber-300" /> Verify access now
          </button>
        </div>

        <aside
          id="campaign-summary"
          class="rounded-3xl border border-amber-300/20 bg-amber-300/[0.06] p-7 sm:p-8"
        >
          <p class="text-xs font-semibold uppercase tracking-[0.22em] text-amber-300">
            Campaign link
          </p>
          <dl class="mt-8 space-y-7">
            <div>
              <dt class="text-xs text-slate-500">Guild</dt>
              <dd class="mt-1 text-sm font-medium text-slate-200">Discord campaign connected</dd>
            </div>
            <div>
              <dt class="text-xs text-slate-500">Current tick</dt>
              <dd id="current-tick-number" class="mt-1 text-3xl font-semibold text-white">
                {@current_scope.campaign.current_tick_number}
              </dd>
            </div>
            <div>
              <dt class="text-xs text-slate-500">Authorization</dt>
              <dd class="mt-1 flex items-center gap-2 text-sm text-emerald-300">
                <.icon name="hero-lock-closed" class="size-4" /> Checked on every action
              </dd>
            </div>
          </dl>
        </aside>
      </section>
    </Layouts.app>
    """
  end
end
