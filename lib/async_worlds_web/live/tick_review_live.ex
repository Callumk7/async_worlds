defmodule AsyncWorldsWeb.TickReviewLive do
  use AsyncWorldsWeb, :live_view
  import AsyncWorldsWeb.AdminComponents
  alias AsyncWorlds.Ticks

  @impl true
  def mount(_params, _session, socket),
    do: {:ok, assign(socket, page_title: "Review world tick", tick: nil, draft: nil)}

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    case integer(id) do
      {:ok, id} -> {:noreply, load(socket, id)}
      _ -> {:noreply, unavailable(socket)}
    end
  end

  @impl true
  def handle_event("refresh", _, socket), do: {:noreply, load(socket, socket.assigns.tick.id)}

  def handle_event("edit_delta", %{"id" => id, "delta" => params}, socket) do
    result =
      with {:ok, id} <- integer(id), {:ok, delta} <- optional_delta(params["amount"]) do
        edit(
          socket,
          params["draft_id"],
          %{type: "clock_delta", clock_id: id, delta: delta},
          params["reason"]
        )
      end

    {:noreply,
     complete(
       socket,
       result,
       "Clock result recomputed. Inspect downstream changes and preview before publishing."
     )}
  end

  def handle_event("edit_news", %{"news" => params}, socket) do
    result =
      case {params["mode"], params["text"]} do
        {"generated", _} ->
          edit(socket, params["draft_id"], %{type: "world_news", text: nil}, params["reason"])

        {"override", text} when is_binary(text) ->
          news = String.split(text, ~r/\n\s*\n/, trim: true)
          edit(socket, params["draft_id"], %{type: "world_news", text: news}, params["reason"])

        _ ->
          {:error, :invalid_edit}
      end

    {:noreply,
     complete(
       socket,
       result,
       "World news updated. The public preview is the exact outgoing content."
     )}
  end

  def handle_event("publish", %{"publish" => params}, socket) do
    if params["confirm"] == "true" do
      case Ticks.publish_tick(campaign_id(socket), socket.assigns.tick.id, params["draft_id"]) do
        {:ok, _} ->
          {:noreply,
           socket
           |> put_flash(:info, "Tick published. State and deliveries committed together.")
           |> push_navigate(to: ~p"/dashboard")}

        {:error, reason} ->
          {:noreply,
           socket |> put_flash(:error, error_message(reason)) |> load(socket.assigns.tick.id)}
      end
    else
      {:noreply,
       put_flash(socket, :error, "Confirm you reviewed the outgoing content before publishing.")}
    end
  end

  def handle_event(_, _, socket),
    do: {:noreply, put_flash(socket, :error, "Invalid action. Reload the review and try again.")}

  defp campaign_id(socket), do: socket.assigns.current_scope.campaign.id

  defp edit(socket, draft_id, operation, reason),
    do:
      Ticks.edit_draft(
        campaign_id(socket),
        socket.assigns.tick.id,
        draft_id,
        operation,
        socket.assigns.current_scope.discord_user_id,
        reason
      )

  defp optional_delta(""), do: {:ok, nil}
  defp optional_delta(value), do: integer(value)

  defp complete(socket, {:ok, _}, message),
    do: socket |> put_flash(:info, message) |> load(socket.assigns.tick.id)

  defp complete(socket, {:error, reason}, _) do
    stale = reason == :stale_draft or match?({:invalid_transition, _, _}, reason)

    socket =
      socket
      |> assign(:stale, socket.assigns.stale || stale)
      |> put_flash(:error, error_message(reason))

    if stale and socket.assigns.preview_ready do
      stream(socket, :review_clocks, review_clocks(socket.assigns.draft, socket.assigns.snapshot),
        reset: true
      )
    else
      socket
    end
  end

  defp unavailable(socket),
    do:
      socket
      |> put_flash(:error, "No reviewable draft is available for that tick in this campaign.")
      |> push_navigate(to: ~p"/dashboard")

  defp load(socket, id) do
    campaign = campaign_id(socket)

    with {:ok, %{status: :in_review} = tick} <- Ticks.fetch_tick(campaign, id),
         {:ok, draft} <- Ticks.fetch_draft(campaign, id),
         {:ok, snapshot} <- Ticks.fetch_snapshot(campaign, id),
         {:ok, edits} <- Ticks.list_review_edits(campaign, id) do
      preview = Ticks.preview_draft(campaign, id, draft.id)

      messages =
        case preview do
          {:ok, outputs} ->
            Enum.with_index(outputs["public"], fn message, index ->
              Map.put(message, :id, index)
            end)

          _ ->
            []
        end

      payload = if match?({:ok, _}, preview), do: draft.payload, else: %{}
      clocks = if match?({:ok, _}, preview), do: review_clocks(draft, snapshot), else: []
      log = Enum.map(payload["log"] || [], &%{id: &1["sequence"], event: &1})

      socket
      |> assign(
        tick: tick,
        draft: draft,
        snapshot: snapshot,
        stale: false,
        preview_ready: match?({:ok, _}, preview),
        news_form:
          params_form(
            %{
              "draft_id" => draft.id,
              "text" => Enum.join(payload["world_news"] || [], "\n\n"),
              "mode" => "override",
              "reason" => ""
            },
            [:draft_id, :text, :mode, :reason], as: :news),
        publish_form:
          params_form(%{"draft_id" => draft.id, "confirm" => "false"}, [:draft_id, :confirm],
            as: :publish
          )
      )
      |> stream(:review_clocks, clocks, reset: true)
      |> stream(:resolution_log, log, reset: true)
      |> stream(:review_edits, edits, reset: true)
      |> stream(:public_preview, messages, reset: true)
    else
      _ -> unavailable(socket)
    end
  end

  defp review_clocks(draft, snapshot) do
    Enum.map(draft.payload["clocks"], fn clock ->
      frozen = Enum.find(snapshot.data["clocks"], &(&1["id"] == clock["id"]))
      override = get_in(draft.payload, ["review", "clock_deltas", to_string(clock["id"])])

      %{
        id: clock["id"],
        clock: clock,
        frozen: frozen,
        form:
          params_form(
            %{
              "draft_id" => draft.id,
              "amount" => if(is_nil(override), do: "", else: to_string(override)),
              "reason" => ""
            },
            [:draft_id, :amount, :reason], as: :delta, id: "draft-clock-#{clock["id"]}")
      }
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.navigation active="review" />
      <section :if={@tick} id="tick-review" class="space-y-7">
        <header class="flex flex-wrap justify-between gap-4">
          <div>
            <p class="text-xs uppercase tracking-widest text-amber-300">
              Private draft · not yet live
            </p><h1 class="mt-2 text-4xl font-semibold tracking-tight">Review tick {@tick.number}</h1><p
              id="draft-revision"
              class="mt-3 text-sm text-slate-400"
            >
              Revision {@draft.revision} · reload after changes in another window.
            </p>
          </div><button
            id="refresh-review"
            phx-click="refresh"
            class="admin-button admin-secondary self-start"
          ><.icon name="hero-arrow-path" class="size-4" /> Reload review</button>
        </header>
        <p
          :if={@stale}
          id="stale-review"
          role="alert"
          class="rounded-xl border border-rose-300/30 bg-rose-300/10 p-4 text-sm text-rose-200"
        >
          This revision is stale. Editing and publication are disabled until you reload and inspect the current review.
        </p>
        <div class="grid gap-7 lg:grid-cols-[1.1fr_1fr]">
          <section class="admin-panel">
            <h2 class="mb-2 text-xl font-semibold">Clock results</h2><p class="mb-5 text-sm text-slate-400">
              Replace a clock's signed tick delta, not its live fill. Blank restores the frozen rate. Completion and triggers recompute; initially-full completion latches remain.
            </p>
            <div id="review-clocks" phx-update="stream" class="space-y-4">
              <p id="review-clocks-empty" class="hidden only:block text-sm text-slate-400">
                No clocks in this tick.
              </p>
              <article
                :for={{dom_id, item} <- @streams.review_clocks}
                id={dom_id}
                class="rounded-xl border border-white/10 p-4"
              >
                <div class="flex justify-between gap-3">
                  <h3 class="font-semibold">{item.clock["name"]}</h3><span class="text-xs text-slate-400">{item.clock[
                    "visibility"
                  ]}</span>
                </div>
                <p id={"clock-result-#{item.id}"} class="mt-3 text-sm">
                  <span class="text-slate-400">Frozen {item.frozen["filled"]}/{item.frozen["segments"]}</span>
                  <.icon name="hero-arrow-right" class="mx-2 size-4" /><span class="text-amber-200">{item.clock[
                    "filled"
                  ]}/{item.clock["segments"]}</span>
                  · {if item.clock["completed"],
                    do: "completed",
                    else: if(item.clock["paused"], do: "paused", else: "running")}
                </p>
                <.form
                  for={item.form}
                  id={"draft-clock-#{item.id}"}
                  phx-submit="edit_delta"
                  phx-value-id={item.id}
                  class="admin-form mt-4 space-y-3"
                >
                  <.input field={item.form[:draft_id]} type="hidden" />
                  <.input
                    field={item.form[:amount]}
                    type="number"
                    label="Override signed delta (blank = frozen behavior)"
                    disabled={@stale || item.frozen["completed"]}
                    class="admin-input"
                  />
                  <.input
                    field={item.form[:reason]}
                    label="Audit reason"
                    required
                    maxlength="2000"
                    disabled={@stale || item.frozen["completed"]}
                    class="admin-input"
                  />
                  <button
                    id={"save-draft-clock-#{item.id}"}
                    disabled={@stale || item.frozen["completed"]}
                    phx-disable-with="Recomputing…"
                    class="admin-button admin-secondary"
                  >Recompute result</button>
                </.form>
              </article>
            </div>
          </section>
          <div class="space-y-7">
            <section class="admin-panel">
              <h2 class="mb-2 text-xl font-semibold">World news</h2><p class="mb-5 text-sm text-slate-400">
                Public narration. Separate paragraphs with a blank line; each at most 2000 characters. Empty text suppresses news.
              </p>
              <.form
                for={@news_form}
                id="world-news-form"
                phx-submit="edit_news"
                class="admin-form space-y-4"
              >
                <fieldset disabled={@stale || !@preview_ready} class="space-y-4">
                  <.input field={@news_form[:draft_id]} type="hidden" />
                  <.input
                    field={@news_form[:mode]}
                    type="select"
                    label="Narration source"
                    options={[
                      "Use this narration": "override",
                      "Restore generated trigger news": "generated"
                    ]}
                    class="admin-input"
                  />
                  <.input
                    field={@news_form[:text]}
                    type="textarea"
                    label="Public world news"
                    rows="7"
                    class="admin-input"
                  />
                  <.input
                    field={@news_form[:reason]}
                    label="Audit reason"
                    required
                    maxlength="2000"
                    class="admin-input"
                  />
                  <button
                    id="save-world-news"
                    phx-disable-with="Saving…"
                    class="admin-button admin-secondary"
                  >Save world news</button>
                </fieldset>
              </.form>
            </section>
            <section class="admin-panel border-amber-300/30">
              <h2 class="text-xl font-semibold">Exact public preview</h2><p class="mb-5 mt-2 text-sm text-slate-400">
                The same content queued for delivery. Hidden clocks and private notifications are excluded; known clocks expose names only.
              </p>
              <p
                :if={!@preview_ready}
                id="preview-error"
                role="alert"
                class="mb-4 text-sm text-rose-300"
              >
                Preview validation failed. Publication is disabled; reload or investigate the draft.
              </p>
              <div id="public-preview" phx-update="stream" class="space-y-3">
                <pre
                  :for={{dom_id, message} <- @streams.public_preview}
                  id={dom_id}
                  class="whitespace-pre-wrap break-words rounded-xl bg-slate-950/70 p-4 font-sans text-sm leading-6"
                >{message["content"]}</pre>
              </div>
              <.form
                for={@publish_form}
                id="publish-form"
                phx-submit="publish"
                class="admin-form mt-6 space-y-4"
              >
                <.input field={@publish_form[:draft_id]} type="hidden" />
                <.input
                  field={@publish_form[:confirm]}
                  type="checkbox"
                  label="I reviewed this revision and its outgoing public content"
                  class="admin-checkbox"
                />
                <p class="text-xs text-slate-400">
                  Publication applies live state and queues deliveries atomically. Published rollback is not available.
                </p>
                <button
                  id="publish-tick"
                  disabled={!@preview_ready || @stale}
                  phx-disable-with="Publishing…"
                  class="admin-button"
                ><.icon name="hero-check-circle" class="size-5" /> Publish approved tick</button>
              </.form>
            </section>
          </div>
        </div>
        <section class="admin-panel">
          <h2 class="mb-5 text-xl font-semibold">Source-labelled consequences</h2>
          <div id="resolution-log" phx-update="stream" class="space-y-3">
            <p id="resolution-log-empty" class="hidden only:block text-sm text-slate-400">
              No state changes or triggers in this revision.
            </p>
            <article
              :for={{dom_id, item} <- @streams.resolution_log}
              id={dom_id}
              class="rounded-xl border border-white/10 p-4 text-sm"
            >
              <p class="font-medium">
                #{item.event["sequence"]} · {item.event["kind"]} · clock #{item.event["clock_id"]}
              </p>
              <p class="mt-1 break-all text-xs text-amber-200">
                {item.event["source"]} · {item.event["phase"]}
              </p>
              <%= if item.event["kind"] == "clock_change" do %>
                <p class="mt-2 text-slate-400">
                  Fill {item.event["before"]["filled"]} → {item.event["after"]["filled"]}; paused {to_string(
                    item.event["before"]["paused"]
                  )} → {to_string(item.event["after"]["paused"])}; completed {to_string(
                    item.event["before"]["completed"]
                  )} → {to_string(item.event["after"]["completed"])}
                </p>
              <% else %>
                <p class="mt-2 text-slate-400">
                  {item.event["type"]} · {item.event["text"] ||
                    "Target clock #{item.event["target_clock_id"]}"}
                </p>
              <% end %>
            </article>
          </div>
        </section>
        <section class="admin-panel">
          <h2 class="mb-5 text-xl font-semibold">Review audit</h2>
          <div id="review-audit" phx-update="stream" class="space-y-3">
            <p id="review-audit-empty" class="hidden only:block text-sm text-slate-400">
              No review edits yet.
            </p>
            <article
              :for={{dom_id, edit} <- @streams.review_edits}
              id={dom_id}
              class="border-b border-white/10 pb-3 text-sm"
            >
              <p>{edit.operation["type"]} · DM {edit.actor_id}</p><p class="mt-1 text-slate-400">
                {edit.reason}
              </p>
            </article>
          </div>
        </section>
      </section>
    </Layouts.app>
    """
  end
end
