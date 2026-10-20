defmodule AsyncWorldsWeb.TickHistoryLive do
  use AsyncWorldsWeb, :live_view
  import AsyncWorldsWeb.AdminComponents
  alias AsyncWorlds.Ticks.History

  @sections [
    events: "Chronicle · established developments",
    manual: "Approved manual changes (including routine pressures)",
    results: "Approved player results",
    clocks: "Approved world clocks",
    rolls: "Recorded dice",
    consequences: "Source-labelled consequences",
    reviews: "Review overrides",
    interventions: "Tick-associated quest interventions",
    audits: "Publication clock audits",
    messages: "Stored outgoing messages"
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Published tick history", history: nil, sections: @sections)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    scope = socket.assigns.current_scope
    guild = scope.campaign.discord_guild_id
    actor = scope.discord_user_id

    result =
      if socket.assigns.live_action == :show do
        with {:ok, pages} <- pages(params) do
          History.fetch(guild, actor, params["id"], pages)
        end
      else
        with {:ok, page} <- page(params["page"]), do: History.list(guild, actor, page)
      end

    socket =
      case result do
        {:ok, %{sections: sections} = history} ->
          metadata = Map.new(sections, fn {key, page} -> {key, Map.delete(page, :items)} end)

          socket =
            assign(socket, history: Map.delete(history, :sections), section_pages: metadata)

          Enum.reduce(@sections, socket, fn
            {key, _}, socket ->
              items = sections[to_string(key)].items

              rows =
                Enum.with_index(items, fn item, index -> %{id: index, data: record(item)} end)

              stream(socket, key, rows, reset: true)
          end)

        {:ok, listing} ->
          socket
          |> assign(history: nil, listing: Map.delete(listing, :items))
          |> stream(:publications, listing.items, reset: true)

        {:error, _} ->
          socket
          |> put_flash(
            :error,
            "Published history is unavailable for that request in this campaign."
          )
          |> push_navigate(to: ~p"/dashboard")
      end

    {:noreply, socket}
  end

  defp pages(params) do
    Enum.reduce_while(History.sections(), {:ok, %{}}, fn key, {:ok, pages} ->
      case page(params[key]) do
        {:ok, value} -> {:cont, {:ok, Map.put(pages, key, value)}}
        error -> {:halt, error}
      end
    end)
  end

  defp page(nil), do: {:ok, 1}

  defp page(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n > 0 and n <= 100_000 -> {:ok, n}
      _ -> {:error, :invalid_page}
    end
  end

  defp page(_), do: {:error, :invalid_page}

  defp record(%AsyncWorlds.Ticks.ReviewEdit{} = edit),
    do:
      Map.take(edit, [
        :id,
        :actor_id,
        :reason,
        :operation,
        :previous_draft_id,
        :draft_id,
        :inserted_at
      ])

  defp record(%AsyncWorlds.Quests.Intervention{} = audit),
    do:
      Map.take(audit, [
        :id,
        :character_id,
        :actor_id,
        :operation,
        :reason,
        :before,
        :after,
        :invalidated_submissions,
        :inserted_at
      ])

  defp record(%AsyncWorlds.Clocks.Audit{} = audit),
    do: Map.take(audit, [:id, :clock_id, :operation, :source, :before, :after, :inserted_at])

  defp record(item), do: item

  defp section_path(history, section_pages, key, page) do
    params = Map.new(section_pages, fn {key, value} -> {key, value.page} end)
    params = Map.put(params, to_string(key), page)
    ~p"/ticks/#{history.tick.id}/history?#{params}"
  end

  attr :value, :any, required: true

  defp saved_fields(assigns) do
    ~H"""
    <%= cond do %>
      <% is_struct(@value, DateTime) -> %>
        <span>{DateTime.to_iso8601(@value)}</span>
      <% is_map(@value) -> %>
        <dl class="space-y-2 border-l border-white/10 pl-3">
          <div :for={{key, value} <- Enum.sort_by(@value, fn {key, _} -> to_string(key) end)}>
            <dt class="text-xs uppercase tracking-wide text-slate-500">{label(key)}</dt>
            <dd class="mt-1 break-words text-sm text-slate-200"><.saved_fields value={value} /></dd>
          </div>
        </dl>
      <% is_list(@value) -> %>
        <ol class="space-y-3 list-decimal pl-5">
          <li :for={value <- @value}><.saved_fields value={value} /></li>
        </ol>
      <% is_nil(@value) -> %>
        <span class="text-slate-500">Not recorded</span>
      <% true -> %>
        <span class="whitespace-pre-wrap">{to_string(@value)}</span>
    <% end %>
    """
  end

  defp label(key), do: key |> to_string() |> String.replace("_", " ")

  defp record_title(:events, record),
    do: record["title"] <> if(record["kind"] == "resolution", do: " · Resolution", else: "")

  defp record_title(:manual, record),
    do: "#{record["after"]["name"]} · #{record["entity"]} · #{record["source"]}"

  defp record_title(:results, record),
    do: "#{record["historical_character"]} · #{record["outcome"] || "approved result"}"

  defp record_title(:clocks, record),
    do:
      "#{record["name"] || "Clock ##{record["id"]}"} · #{record["filled"]}/#{record["segments"]}"

  defp record_title(:rolls, record),
    do:
      "Character ##{get_in(record, ["input", "character_id"])} · die #{(record["die_index"] || 0) + 1}: #{record["value"]}"

  defp record_title(:consequences, record),
    do: "#{record["kind"]} · #{record["source"]}"

  defp record_title(:reviews, record),
    do: "#{record.operation["type"]} · DM #{record.actor_id}"

  defp record_title(:interventions, record),
    do: "#{record.operation} · character ##{record.character_id} · DM #{record.actor_id}"

  defp record_title(:audits, record),
    do: "Clock ##{record.clock_id} · #{record.operation} · #{record.source}"

  defp record_summary(:events, record), do: record["text"]
  defp record_summary(:results, record), do: record["text"]
  defp record_summary(key, record) when key in [:reviews, :interventions], do: record.reason
  defp record_summary(_, _), do: nil

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.navigation active="history" />
      <section id="tick-history" class="space-y-7">
        <header>
          <p class="text-xs uppercase tracking-widest text-amber-300">
            Private DM archive · read only
          </p>
          <h1 class="mt-3 text-4xl font-semibold tracking-tight">
            {if @history, do: "Published tick #{@history.tick.number}", else: "Published tick history"}
          </h1>
          <p class="mt-3 text-sm text-slate-400">
            Saved approved content, never reconstructed from current characters, clocks or quests.
            Missing historical names are shown as stable IDs. This is not a complete administration audit.
          </p>
          <.link
            id="history-chronicle"
            navigate={~p"/events"}
            class="mt-3 inline-block text-sm text-amber-200 hover:underline"
          >Explore the connected Event chronicle</.link>
        </header>

        <%= if @history do %>
          <section id="publication-identity" class="admin-panel space-y-2 text-sm">
            <p>Published {DateTime.to_iso8601(@history.publication.inserted_at)}</p>
            <p class="break-all">
              Selected draft {@history.publication.draft_id} · revision {@history.revision}
            </p>
            <p class="break-all">Frozen input revision {@history.input_revision}</p>
            <.link
              id="history-back"
              navigate={~p"/ticks/history"}
              class="admin-button admin-secondary mt-3"
            >
              <.icon name="hero-arrow-left" class="size-4" /> All published ticks
            </.link>
          </section>
          <section id="history-world-news" class="admin-panel">
            <h2 class="text-xl font-semibold">Approved world news</h2>
            <p class="mt-3 whitespace-pre-wrap text-sm">{@history.world_news}</p>
          </section>
          <section
            :for={{key, title} <- @sections}
            id={"history-#{key}"}
            class="admin-panel space-y-5"
          >
            <div class="flex flex-wrap justify-between gap-3">
              <h2 class="text-xl font-semibold">{title}</h2>
              <.link
                :if={key == :messages}
                id="history-delivery-controls"
                navigate={~p"/dashboard"}
                class="text-sm text-amber-300 hover:text-amber-100"
              >
                Existing delivery retry controls
                <.icon name="hero-arrow-top-right-on-square" class="size-4" />
              </.link>
            </div>
            <p :if={key == :messages} class="text-sm text-slate-400">
              Message content is immutable. Delivery status below is current and may change independently.
              Opening prompts and reminders are not approved publication messages.
            </p>
            <div id={"history-#{key}-records"} phx-update="stream" class="space-y-4">
              <p id={"history-#{key}-empty"} class="hidden only:block text-sm text-slate-500">
                No records on this page.
              </p>
              <article
                :for={{dom_id, item} <- Map.fetch!(@streams, key)}
                id={dom_id}
                class="rounded-xl border border-white/10 p-4 transition-colors hover:border-amber-300/20"
              >
                <%= if key == :messages do %>
                  <p class="text-xs uppercase tracking-wide text-amber-200">
                    {item.data.audience}{if item.data.route, do: " · #{item.data.route}"} · recipient {item.data.recipient} · chunk {item.data.chunk}
                    <span :if={item.data.character_id}>· character {item.data.character_id}</span>
                  </p>
                  <pre class="mt-3 whitespace-pre-wrap break-words font-sans text-sm">{item.data.content}</pre>
                  <div
                    id={"history-message-status-#{item.id}"}
                    class="mt-4 border-t border-white/10 pt-3 text-xs text-slate-400"
                  >
                    Current delivery status:
                    <%= if item.data.delivery do %>
                      {item.data.delivery.status} · attempts {item.data.delivery.attempts} · delivery {item.data.delivery.id}
                      <span :if={item.data.delivery.error_class}>· {item.data.delivery.error_class}</span>
                    <% else %>
                      No associated delivery record
                    <% end %>
                  </div>
                <% else %>
                  <h3 class="break-words text-sm font-semibold text-amber-100">
                    <%= if key == :events do %>
                      <.link
                        navigate={~p"/events/#{@history.tick.id}?#{%{"event" => item.data["id"]}}"}
                        class="hover:underline"
                      >{record_title(key, item.data)}</.link>
                    <% else %>
                      {record_title(key, item.data)}
                    <% end %>
                  </h3>
                  <p
                    :if={record_summary(key, item.data)}
                    class="mt-2 whitespace-pre-wrap text-sm text-slate-300"
                  >
                    {record_summary(key, item.data)}
                  </p>
                  <details class="mt-4">
                    <summary class="cursor-pointer text-xs text-slate-400 transition-colors hover:text-amber-200">
                      Inspect saved identities and state
                    </summary>
                    <div class="mt-4"><.saved_fields value={item.data} /></div>
                  </details>
                <% end %>
              </article>
            </div>
            <div class="flex items-center gap-4 text-sm">
              <.link
                :if={@section_pages[to_string(key)].page > 1}
                id={"history-#{key}-previous"}
                patch={
                  section_path(@history, @section_pages, key, @section_pages[to_string(key)].page - 1)
                }
                class="admin-button admin-secondary"
              >Previous</.link>
              <span class="text-slate-500">Page {@section_pages[to_string(key)].page}</span>
              <.link
                :if={@section_pages[to_string(key)].more?}
                id={"history-#{key}-next"}
                patch={
                  section_path(@history, @section_pages, key, @section_pages[to_string(key)].page + 1)
                }
                class="admin-button admin-secondary"
              >Next</.link>
            </div>
          </section>
        <% else %>
          <div id="published-ticks" phx-update="stream" class="space-y-4">
            <p id="published-ticks-empty" class="hidden only:block admin-panel text-slate-400">
              No published ticks yet. Drafts do not appear in history.
            </p>
            <article
              :for={{dom_id, tick} <- @streams.publications}
              id={dom_id}
              class="admin-panel flex flex-wrap items-center justify-between gap-4"
            >
              <div>
                <h2 class="text-xl font-semibold">Tick {tick.number}</h2><p class="mt-2 text-sm text-slate-400">
                  {DateTime.to_iso8601(tick.published_at)}
                </p>
                <p :for={event <- tick.events} class="mt-3 text-sm text-amber-100">
                  <.link
                    navigate={~p"/events/#{tick.id}?#{%{"event" => event["id"]}}"}
                    class="hover:underline"
                  >{event["title"]}</.link>
                  — {event["text"]}
                </p>
              </div>
              <.link
                id={"open-history-#{tick.id}"}
                navigate={~p"/ticks/#{tick.id}/history"}
                class="admin-button admin-secondary"
              >Inspect publication <.icon name="hero-arrow-right" class="size-4" /></.link>
            </article>
          </div>
          <div class="flex items-center gap-4">
            <.link
              :if={@listing.page > 1}
              id="history-previous"
              patch={~p"/ticks/history?page=#{@listing.page - 1}"}
              class="admin-button admin-secondary"
            >Newer ticks</.link>
            <span class="text-sm text-slate-500">Page {@listing.page}</span>
            <.link
              :if={@listing.more?}
              id="history-next"
              patch={~p"/ticks/history?page=#{@listing.page + 1}"}
              class="admin-button admin-secondary"
            >Older ticks</.link>
          </div>
        <% end %>
      </section>
    </Layouts.app>
    """
  end
end
