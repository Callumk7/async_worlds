defmodule AsyncWorldsWeb.DashboardLive do
  use AsyncWorldsWeb, :live_view
  import AsyncWorldsWeb.AdminComponents
  alias AsyncWorlds.Campaigns
  alias AsyncWorlds.DM.{Clocks, Deliveries, Ticks}
  alias AsyncWorlds.Quests.Submissions

  @filter_fields [:status, :kind, :tick, :recipient]

  @status_filters %{
    "pending" => :pending,
    "sending" => :sending,
    "sent" => :sent,
    "failed" => :failed,
    "ambiguous" => :ambiguous
  }

  @kind_filters %{"public" => :public, "private" => :private}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Campaign command center",
       opening: nil,
       opening_stale: false,
       opening_form: opening_form(""),
       opening_confirmation: confirmation_form(),
       delivery_filters: %{},
       delivery_filter_form: filter_form(%{})
     )
     |> stream(:opening_chunks, [])
     |> refresh()}
  end

  @impl true
  def handle_event("refresh_authorization", _params, socket), do: {:noreply, refresh(socket)}

  def handle_event("filter_deliveries", %{"filter" => params}, socket) do
    filters = parse_filters(scope(socket), params)

    {:noreply,
     socket
     |> assign(delivery_filters: filters, delivery_filter_form: filter_form(params))
     |> refresh()}
  end

  def handle_event("opening_changed", %{"opening" => %{"narration" => text}}, socket)
      when is_binary(text) do
    {:noreply,
     socket
     |> assign(
       opening_form: opening_form(text),
       opening_stale: socket.assigns.opening != nil,
       opening_confirmation: confirmation_form()
     )}
  end

  def handle_event("prepare_opening", %{"opening" => params} = input, socket)
      when map_size(input) == 1 do
    case Ticks.prepare_opening(scope(socket), params) do
      {:ok, opening} ->
        {:noreply,
         socket
         |> assign(
           opening:
             opening |> Map.delete(:messages) |> Map.put(:chunk_count, length(opening.messages)),
           opening_stale: false,
           opening_form: opening_form(opening.narration),
           opening_confirmation: confirmation_form()
         )
         |> stream(:opening_chunks, opening.messages, reset: true)}

      {:error, reason} ->
        {:noreply, socket |> refresh_overview() |> stale_opening(reason)}
    end
  end

  def handle_event(
        "open_prepared_tick",
        %{"approval" => %{"confirm" => "true"} = approval} = input,
        socket
      )
      when map_size(input) == 1 and map_size(approval) == 1 do
    result =
      if socket.assigns.opening && not socket.assigns.opening_stale do
        Ticks.open_prepared_tick(scope(socket), socket.assigns.opening.token)
      else
        {:error, :stale_preparation}
      end

    case result do
      {:ok, _} ->
        {:noreply,
         socket
         |> clear_opening()
         |> complete(
           result,
           "Tick opened. Reviewed public briefing and private prompts queued; inspect deliveries for status or targeted retry."
         )}

      {:error, reason} ->
        {:noreply, socket |> refresh_overview() |> stale_opening(reason)}
    end
  end

  def handle_event("open_prepared_tick", _, socket),
    do:
      {:noreply,
       put_flash(
         socket,
         :error,
         "Confirm that you inspected all opening chunks and the destination."
       )}

  def handle_event("open_tick", _params, socket) do
    {:noreply,
     complete(
       clear_opening(socket),
       Ticks.open_tick(scope(socket)),
       "Tick opened. Default public briefing and private prompts queued."
     )}
  end

  def handle_event("close_tick", %{"id" => id}, socket) do
    result = with {:ok, id} <- integer(id), do: Ticks.close_tick(scope(socket), id)

    {:noreply,
     complete(socket, result, "Inputs frozen. Resolution is queued; refresh to see progress.")}
  end

  def handle_event("retry_delivery", %{"id" => id, "retry" => params}, socket) do
    result =
      with {:ok, id} <- integer(id), {:ok, generation} <- integer(params["generation"]) do
        Deliveries.retry_delivery(scope(socket), id, generation,
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

  defp opening_form(text) do
    {%{narration: text}, %{narration: :string}}
    |> Ecto.Changeset.change()
    |> to_form(as: :opening)
  end

  defp confirmation_form do
    {%{confirm: false}, %{confirm: :boolean}}
    |> Ecto.Changeset.change()
    |> to_form(as: :approval)
  end

  defp clear_opening(socket) do
    socket
    |> assign(opening: nil, opening_stale: false, opening_confirmation: confirmation_form())
    |> stream(:opening_chunks, [], reset: true)
  end

  defp stale_opening(socket, reason) do
    socket
    |> assign(opening_stale: true, opening_confirmation: confirmation_form())
    |> put_flash(:error, error_message(reason))
  end

  defp scope(socket), do: socket.assigns.current_scope

  defp refresh(socket), do: socket |> refresh_overview() |> check_opening()

  defp refresh_overview(socket) do
    scope = socket.assigns.current_scope

    {:ok, campaign} =
      Campaigns.authorize_dm(scope.campaign.discord_guild_id, scope.discord_user_id)

    socket = assign(socket, :current_scope, %{scope | campaign: campaign})
    scope = scope(socket)
    {:ok, tick} = Ticks.active_tick(scope)
    {:ok, clocks} = Clocks.list_clocks(scope)
    jobs = if tick, do: elem(Ticks.resolution_jobs(scope, tick.id), 1), else: []

    roster =
      if tick do
        case Submissions.readiness_roster(campaign, scope.discord_user_id, tick.id) do
          {:ok, roster} -> roster
          {:error, _} -> nil
        end
      end

    {:ok, recent_audits} = Clocks.recent_audits(scope)

    audits =
      Enum.map(recent_audits, fn audit ->
        %{id: audit.id, audit: audit}
      end)

    records = deliveries_raw(socket, scope)

    ticks =
      tick_map(scope, Enum.map(records, & &1.tick_id) ++ Enum.map(audits, & &1.audit.tick_id))

    deliveries =
      Enum.map(records, fn delivery ->
        %{
          id: delivery.id,
          delivery: delivery,
          tick: ticks[delivery.tick_id],
          form:
            params_form(
              %{"generation" => to_string(delivery.generation), "confirm" => "false"},
              [:generation, :confirm],
              as: :retry,
              id: "retry-delivery-#{delivery.id}"
            )
        }
      end)

    audits = Enum.map(audits, fn item -> Map.put(item, :tick, ticks[item.audit.tick_id]) end)

    socket
    |> assign(
      tick: tick,
      clock_count: length(clocks),
      readiness: roster && roster.counts,
      roster: roster,
      refreshed_at: DateTime.utc_now() |> DateTime.truncate(:second)
    )
    |> stream(:clocks, clocks, reset: true)
    |> stream(:audits, audits, reset: true)
    |> stream(:jobs, jobs, reset: true)
    |> stream(:deliveries, deliveries, reset: true)
    |> stream(:roster, (roster && roster.rows) || [], reset: true)
  end

  defp check_opening(%{assigns: %{opening: nil}} = socket), do: socket

  defp check_opening(socket) do
    case Ticks.preview_opening(scope(socket), socket.assigns.opening.token) do
      {:ok, _} -> socket
      {:error, reason} -> stale_opening(socket, reason)
    end
  end

  defp deliveries_raw(socket, scope) do
    filters = socket.assigns.delivery_filters

    case filters do
      %{tick_id: :unknown} ->
        []

      filters ->
        case Deliveries.search_deliveries(scope, filters) do
          {:ok, deliveries} -> deliveries
          {:error, :invalid_filter} -> []
        end
    end
  end

  defp tick_map(_scope, []), do: %{}

  defp tick_map(scope, tick_ids) do
    ids = tick_ids |> Enum.reject(&is_nil/1) |> Enum.uniq()
    {:ok, ticks} = Ticks.fetch_ticks(scope, ids)
    Map.new(ticks, &{&1.id, &1})
  end

  defp filter_form(params),
    do:
      params_form(Map.new(@filter_fields, &{&1, params[to_string(&1)] || ""}), @filter_fields,
        as: :filter,
        id: "delivery-filters"
      )

  # Parses the DM-facing filter form into whitelisted domain filters. A tick
  # number that does not resolve in this campaign yields the `:unknown` marker,
  # which shows an empty result instead of widening the search.
  defp parse_filters(scope, params) do
    %{}
    |> put_filter(:status, @status_filters[params["status"] || ""])
    |> put_filter(:kind, @kind_filters[params["kind"] || ""])
    |> put_tick_filter(scope, params["tick"])
    |> put_recipient_filter(params["recipient"])
  end

  defp put_filter(filters, _key, nil), do: filters
  defp put_filter(filters, key, value), do: Map.put(filters, key, value)

  defp put_tick_filter(filters, scope, value) do
    case String.trim(value || "") do
      "" ->
        filters

      trimmed ->
        case Integer.parse(trimmed) do
          {number, ""} when number in 1..2_147_483_647 ->
            case Ticks.fetch_tick_by_number(scope, number) do
              {:ok, tick} -> Map.put(filters, :tick_id, tick.id)
              {:error, _} -> Map.put(filters, :tick_id, :unknown)
            end

          _ ->
            Map.put(filters, :tick_id, :unknown)
        end
    end
  end

  defp put_recipient_filter(filters, value) do
    case String.trim(value || "") do
      "" -> filters
      recipient -> Map.put(filters, :recipient_id, recipient)
    end
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
          <div class="text-right">
            <button
              id="refresh-authorization"
              phx-click="refresh_authorization"
              class="admin-button admin-secondary"
            >
              <.icon name="hero-arrow-path" class="size-4" /> Refresh status
            </button>
            <p id="dashboard-freshness" class="mt-2 text-xs text-slate-500">
              Refreshed {Calendar.strftime(@refreshed_at, "%Y-%m-%d %H:%M:%S")} UTC · this page
              updates only on explicit refresh.
            </p>
          </div>
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
            <p :if={@readiness} id="quest-readiness" class="mt-2 text-sm text-slate-400">
              {@readiness.submitted}/{@readiness.active} quest choices ready · {@readiness.missing} missing.
              Counts are informational; close whenever you are ready.
            </p>
            <p
              :if={@tick && @tick.status == :resolving}
              id="resolution-pending"
              class="mt-2 text-sm text-amber-200"
            >
              Frozen quest choices and world inputs are queued for private resolution; management remains locked until publication. Refresh to check the job status or draft.
            </p>
          </div>
          <div class="flex flex-wrap gap-3">
            <button
              id="open-tick"
              phx-click="open_tick"
              disabled={@tick != nil}
              phx-disable-with="Opening…"
              data-confirm="Open with the current roster briefing and no narration? Public briefing and private prompts will be queued."
              class="admin-button admin-secondary"
            >
              Open with default briefing
            </button>
            <button
              :if={@tick}
              id="close-tick"
              phx-click="close_tick"
              phx-value-id={@tick.id}
              disabled={@tick.status != :open}
              data-confirm="Close this tick and freeze world and quest inputs? Clock and character management will lock until publication."
              phx-disable-with="Closing…"
              class="admin-button admin-secondary"
            >
              Close & resolve
            </button>
            <.link
              :if={@tick && @tick.status == :in_review}
              id="review-tick"
              navigate={~p"/ticks/#{@tick.id}/review"}
              class="admin-button"
            >
              Review draft <.icon name="hero-arrow-right" class="size-4" />
            </.link>
          </div>
        </section>

        <section
          :if={is_nil(@tick) || @opening != nil}
          id="tick-opening"
          class="admin-panel space-y-5"
        >
          <div>
            <h2 class="text-lg font-semibold">Prepare next tick opening</h2>
            <p class="mt-2 text-sm text-slate-400">
              Preparation sends and saves nothing. Opening saves these exact public chunks and
              queues their delivery together with existing private quest prompts.
            </p>
          </div>
          <.form
            for={@opening_form}
            id="opening-form"
            phx-change="opening_changed"
            phx-submit="prepare_opening"
          >
            <.input
              field={@opening_form[:narration]}
              type="textarea"
              label="Optional public opening narration (not world news)"
            />
            <button id="prepare-opening" class="admin-button" phx-disable-with="Preparing…">
              Prepare / reload exact preview
            </button>
          </.form>
          <%= if @opening do %>
            <div id="opening-preview" class="space-y-4">
              <h3 class="font-semibold">
                Exact public opening preview · Tick {@opening.tick_number}
              </h3>
              <p id="opening-channel" class="text-sm text-amber-200">
                Public channel: {@opening.public_channel_id} · all {@opening.chunk_count} chunks
              </p>
              <p :if={@opening_stale} id="opening-stale" role="alert" class="text-sm text-rose-300">
                Preparation is stale or invalid. The old preview is retained; deliberately prepare again and inspect every chunk before opening.
              </p>
            </div>
          <% end %>
          <div id="opening-chunks" phx-update="stream" class="space-y-4">
            <article
              :for={{id, chunk} <- @streams.opening_chunks}
              id={id}
              class="rounded-xl border border-slate-700 p-4"
            >
              <p class="mb-3 text-xs text-slate-400">
                Chunk {chunk.chunk_index} · channel {chunk.recipient_id}
              </p>
              <div class="whitespace-pre-wrap break-words text-sm font-sans">{chunk.content}</div>
            </article>
          </div>
          <.form
            :if={@opening}
            for={@opening_confirmation}
            id="opening-approval"
            phx-submit="open_prepared_tick"
          >
            <.input
              field={@opening_confirmation[:confirm]}
              type="checkbox"
              label="I inspected all current public chunks and the destination. Queue this briefing when opening."
            />
            <button
              id="open-prepared-tick"
              disabled={@opening_stale}
              class="admin-button"
              phx-disable-with="Opening…"
            >
              Open & queue inspected briefing
            </button>
          </.form>
        </section>

        <section id="readiness-roster" class="admin-panel">
          <div class="mb-5 flex flex-wrap items-center justify-between gap-3">
            <h2 class="text-lg font-semibold">Readiness roster</h2>
            <.link
              id="roster-manage-characters"
              navigate={~p"/characters"}
              class="text-sm text-amber-300 hover:text-amber-100"
            >
              Manage characters
            </.link>
          </div>
          <%= if is_nil(@tick) do %>
            <p id="roster-no-tick" class="text-sm text-slate-400">
              No active tick. Open the next tick to track who still owes a choice.
            </p>
          <% else %>
            <p :if={@roster && @roster.frozen} id="roster-frozen" class="mb-4 text-sm text-slate-400">
              Tick {@roster.tick_number} is closed; this roster reflects the frozen inputs, and live
              management is locked until publication.
            </p>
            <div id="roster-rows" phx-update="stream" class="space-y-3">
              <p id="roster-rows-empty" class="hidden only:block text-sm text-slate-400">
                No characters yet. Create characters to track their readiness.
              </p>
              <article
                :for={{dom_id, row} <- @streams.roster}
                id={dom_id}
                class="rounded-xl border border-white/10 p-4"
              >
                <div class="flex flex-wrap items-center justify-between gap-4">
                  <div>
                    <p class="font-medium">
                      <.link navigate={~p"/characters"} class="text-slate-100 hover:text-amber-100">
                        {row.name}
                      </.link>
                      <span
                        :if={row.unassigned}
                        id={"roster-unassigned-#{row.character_id}"}
                        class="ml-2 rounded-full bg-white/10 px-2 py-0.5 text-xs text-slate-300"
                      >
                        Unassigned · DM controlled
                      </span>
                    </p>
                    <p class="mt-1 text-xs text-slate-400">
                      <%= if row.unassigned do %>
                        No linked Discord player
                      <% else %>
                        Player {row.discord_user_id}
                      <% end %>
                    </p>
                  </div>
                  <div class="text-right">
                    <%= if row.state == :no_active_quest do %>
                      <p class="text-sm text-slate-400">No active quest</p>
                    <% else %>
                      <p class="text-sm">
                        <.link navigate={~p"/quests"} class="text-amber-300 hover:text-amber-100">
                          {row.quest_name || "Quest"}
                        </.link>
                        <span class="text-slate-400">· node {row.node_id}</span>
                      </p>
                    <% end %>
                    <p
                      id={"roster-state-#{row.character_id}"}
                      class={[
                        "mt-1 text-sm font-medium",
                        row.state == :submitted && "text-emerald-300",
                        row.state == :missing && "text-amber-200",
                        row.state == :no_active_quest && "text-slate-400"
                      ]}
                    >
                      {roster_state_label(row.state)}
                    </p>
                    <p
                      :if={row.invalidated}
                      id={"roster-invalidated-#{row.character_id}"}
                      class="mt-1 text-xs text-rose-300"
                    >
                      Earlier choice is no longer eligible; a new choice is needed.
                    </p>
                  </div>
                </div>
              </article>
            </div>
          <% end %>
        </section>

        <div class="grid gap-8 lg:grid-cols-[1.2fr_1fr]">
          <section class="admin-panel">
            <div class="mb-5 flex items-center justify-between">
              <h2 class="text-lg font-semibold">
                Live clocks <span class="text-sm text-slate-500">{@clock_count}</span>
              </h2>
              <.link
                id="manage-clocks"
                navigate={~p"/clocks"}
                class="text-sm text-amber-300 hover:text-amber-100"
              >
                Manage clocks
              </.link>
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
                  <h3 class="font-medium">{clock.name}</h3>
                  <span class="text-xs text-slate-400">
                    {clock.visibility} · {if clock.completed,
                      do: "completed",
                      else: if(clock.paused, do: "paused", else: "running")}
                  </span>
                </div>
                <div class="mt-3 flex items-center gap-4">
                  <progress
                    aria-label={"#{clock.name} fill"}
                    value={clock.filled}
                    max={clock.segments}
                    class="h-2 w-full accent-amber-300"
                  ></progress>
                  <span class="whitespace-nowrap text-sm tabular-nums text-amber-200">
                    {clock.filled}/{clock.segments}
                  </span>
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
                :for={{dom_id, item} <- @streams.audits}
                id={dom_id}
                class="border-b border-white/10 pb-3 text-sm"
              >
                <p>
                  <.link navigate={~p"/clocks"} class="text-amber-300 hover:text-amber-100">
                    {clock_audit_name(item.audit)}
                  </.link>
                  <span
                    :if={clock_audit_hidden?(item.audit)}
                    class="ml-1 rounded-full bg-white/10 px-2 py-0.5 text-xs text-slate-300"
                  >
                    hidden
                  </span>
                  · {item.audit.operation}
                  <span class="text-amber-200">
                    {item.audit.before["filled"] || 0} → {item.audit.after["filled"]}
                  </span>
                </p>
                <p class="mt-1 break-all text-xs text-slate-500">
                  <%= if item.tick do %>
                    <span id={"audit-tick-#{item.audit.id}"}>Tick {item.tick.number}</span> ·
                  <% end %>
                  {item.audit.source} · {Calendar.strftime(
                    item.audit.inserted_at,
                    "%Y-%m-%d %H:%M:%S"
                  )} UTC
                </p>
              </article>
            </div>
          </section>
        </div>

        <section class="admin-panel">
          <h2 class="mb-2 text-lg font-semibold">Resolution jobs</h2>
          <p class="mb-5 text-sm text-slate-400">
            Failed processing keeps the tick locked; investigate discarded or cancelled jobs before retrying via authorized operations.
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
              <span class={job.state in ["retryable", "discarded", "cancelled"] && "text-rose-300"}>
                {job.state}
              </span>
              · attempts {job.attempt}/{job.max_attempts}
            </p>
          </div>
        </section>

        <section class="admin-panel">
          <h2 class="text-lg font-semibold">
            Outgoing deliveries <span class="text-xs text-slate-500">Latest 50</span>
          </h2>
          <p class="mb-5 mt-2 text-sm text-slate-400">
            Retry a specific failed send, never republish. Ambiguous sends may already exist in Discord.
          </p>
          <.form
            for={@delivery_filter_form}
            id="delivery-filters"
            phx-change="filter_deliveries"
            class="admin-form mb-5 flex flex-wrap items-end gap-3"
          >
            <.input
              field={@delivery_filter_form[:status]}
              type="select"
              label="Status"
              options={[
                All: "",
                Pending: "pending",
                Sending: "sending",
                Sent: "sent",
                Failed: "failed",
                Ambiguous: "ambiguous"
              ]}
              class="admin-input"
            />
            <.input
              field={@delivery_filter_form[:kind]}
              type="select"
              label="Kind"
              options={[All: "", Public: "public", Private: "private"]}
              class="admin-input"
            />
            <.input
              field={@delivery_filter_form[:tick]}
              type="text"
              label="Tick number"
              placeholder="Any"
              class="admin-input"
            />
            <.input
              field={@delivery_filter_form[:recipient]}
              type="text"
              label="Recipient ID"
              placeholder="Any"
              class="admin-input"
            />
          </.form>
          <div id="delivery-list" phx-update="stream" class="space-y-4">
            <p id="delivery-list-empty" class="hidden only:block text-sm text-slate-400">
              Nothing matches the current filters.
            </p>
            <article
              :for={{dom_id, item} <- @streams.deliveries}
              id={dom_id}
              class="rounded-xl border border-white/10 p-4"
            >
              <div class="flex flex-wrap items-center justify-between gap-4">
                <div>
                  <p class="font-medium">
                    <span :if={item.tick}>Tick {item.tick.number}</span>
                    <span :if={is_nil(item.tick)}>Tick {item.delivery.tick_id}</span>
                    · {item.delivery.kind} ·
                    <span
                      id={"delivery-status-#{item.id}"}
                      class={delivery_status_class(item.delivery.status)}
                    >
                      {item.delivery.status}
                    </span>
                    <.link
                      :if={item.tick && item.tick.status == :published}
                      id={"delivery-history-#{item.id}"}
                      navigate={~p"/ticks/#{item.tick.id}/history"}
                      class="ml-2 text-xs text-amber-300 hover:text-amber-100"
                    >
                      History
                    </.link>
                    <.link
                      :if={item.tick && item.tick.status == :in_review}
                      id={"delivery-review-#{item.id}"}
                      navigate={~p"/ticks/#{item.tick.id}/review"}
                      class="ml-2 text-xs text-amber-300 hover:text-amber-100"
                    >
                      Review
                    </.link>
                  </p>
                  <p class="mt-1 text-xs text-slate-400">
                    Recipient {item.delivery.recipient_id} · attempts {item.delivery.attempts}
                    <span :if={item.delivery.error_class}>
                      · {item.delivery.error_class} error
                    </span>
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
                  >
                    Retry this delivery
                  </button>
                </.form>
              </div>
            </article>
          </div>
        </section>
      </section>
    </Layouts.app>
    """
  end

  defp roster_state_label(:submitted), do: "Submitted"
  defp roster_state_label(:missing), do: "Missing choice"
  defp roster_state_label(:no_active_quest), do: "No active quest"

  defp clock_audit_name(audit),
    do: audit.after["name"] || audit.before["name"] || "Clock ##{audit.clock_id}"

  defp clock_audit_hidden?(audit),
    do: audit.after["visibility"] == "hidden" or audit.before["visibility"] == "hidden"

  defp delivery_status_class(:failed), do: "text-rose-300"
  defp delivery_status_class(:ambiguous), do: "text-amber-200"
  defp delivery_status_class(:sent), do: "text-emerald-300"
  defp delivery_status_class(_), do: "text-slate-300"

  defp status_label(:in_review), do: "in review"
  defp status_label(status), do: to_string(status)
end
