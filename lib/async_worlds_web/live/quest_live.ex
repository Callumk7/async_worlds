defmodule AsyncWorldsWeb.QuestLive do
  use AsyncWorldsWeb, :live_view
  import AsyncWorldsWeb.AdminComponents
  alias AsyncWorlds.Quests

  @impl true
  def mount(_, _, socket) do
    {:ok, assign(socket, page_title: "Personal quests", selected: nil)}
  end

  @impl true
  def handle_params(params, _, socket) do
    {:noreply, load(socket, params["character_id"])}
  end

  @impl true
  def handle_event("select", %{"id" => id}, socket) do
    {:noreply, push_patch(socket, to: ~p"/quests?character_id=#{id}")}
  end

  def handle_event("refresh", _, socket), do: {:noreply, load(socket, selected_id(socket))}

  def handle_event(operation, %{"intervention" => params}, socket)
      when operation in ["assign", "swap", "move", "end"] and is_map(params) do
    result = perform(operation, params, socket)

    socket =
      case result do
        {:ok, _} ->
          socket |> load(selected_id(socket)) |> put_flash(:info, success_message(operation))

        {:error, reason} ->
          socket |> load(selected_id(socket)) |> put_flash(:error, error_message(reason))
      end

    {:noreply, socket}
  end

  def handle_event(_, _, socket),
    do: {:noreply, put_flash(socket, :error, "Choose a character and an action, then try again.")}

  defp perform(operation, params, socket) do
    selected = socket.assigns.selected

    if selected do
      campaign = socket.assigns.current_scope.campaign
      actor = socket.assigns.current_scope.discord_user_id
      opts = [reason: params["reason"], expected_progression: selected.progression]

      case operation do
        "assign" ->
          Quests.assign(campaign, actor, selected.id, params["revision_id"], opts)

        "swap" ->
          if selected.progression,
            do: Quests.swap(campaign, actor, selected.id, params["revision_id"], opts),
            else: {:error, :not_active}

        "move" ->
          if selected.progression,
            do: Quests.move(campaign, actor, selected.progression.id, params["node_id"], opts),
            else: {:error, :not_active}

        "end" ->
          if selected.progression,
            do: Quests.end_quest(campaign, actor, selected.progression.id, opts),
            else: {:error, :not_active}
      end
    else
      {:error, :not_found}
    end
  end

  defp selected_id(socket), do: socket.assigns.selected && socket.assigns.selected.id

  defp load(socket, character_id) do
    scope = socket.assigns.current_scope

    case Quests.management_state(scope.campaign, scope.discord_user_id, character_id) do
      {:ok, state} ->
        apply_state(socket, state)

      {:error, reason} ->
        # Failed/foreign selections must not leave an old character targeted.
        # Authorization can change after LiveAuth's event hook but before this
        # query acquires the campaign lock. Do not crash or retain private state.
        case Quests.management_state(scope.campaign, scope.discord_user_id) do
          {:ok, state} -> socket |> apply_state(state) |> put_flash(:error, error_message(reason))
          {:error, _} -> redirect(socket, to: ~p"/login")
        end
    end
  end

  defp apply_state(socket, state) do
    revision_options =
      Enum.map(state.revisions, &{"#{&1.quest_name} · v#{&1.number} (#{&1.content_id})", &1.id})

    selected = state.selected
    progression = selected && selected.progression
    nodes = if progression, do: selected.revision.definition["nodes"], else: []

    current_node =
      if progression, do: Quests.Rules.node(selected.revision.definition, progression.node_id)

    node_options =
      Enum.map(nodes, &{&1["id"] <> if(&1["ending"], do: " · ending", else: ""), &1["id"]})

    socket
    |> assign(
      selected: selected,
      locked: state.locked,
      character_count: length(state.characters),
      revision_options: revision_options,
      node_options: node_options,
      current_node: current_node,
      assignment_form:
        params_form(%{"revision_id" => "", "reason" => ""}, [:revision_id, :reason],
          as: :intervention
        ),
      move_form:
        params_form(
          %{"node_id" => if(progression, do: progression.node_id, else: ""), "reason" => ""},
          [:node_id, :reason], as: :intervention),
      end_form: params_form(%{"reason" => ""}, [:reason], as: :intervention)
    )
    |> stream(:characters, state.characters, reset: true)
    |> stream(:interventions, state.audits, reset: true)
  end

  defp success_message("assign"),
    do: "Quest assigned at its start node. Characters progress independently."

  defp success_message("swap"),
    do:
      "Quest replaced at its start node. Any open choice was cleared; the player must choose again."

  defp success_message("move"),
    do:
      "Position saved. Actual node changes clear the open choice; ending nodes complete the quest."

  defp success_message("end"),
    do: "Quest ended and any open choice cleared. The character can receive a new quest."

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.navigation active="quests" />
      <section id="quest-management" class="space-y-7">
        <header class="flex flex-wrap items-end justify-between gap-5">
          <div>
            <p class="text-xs uppercase tracking-[0.22em] text-amber-300">Personal journeys</p>
            <h1 class="mt-2 text-4xl font-semibold tracking-tight">Quest operations</h1>
            <p class="mt-3 max-w-2xl text-sm leading-relaxed text-slate-400">
              Assign existing quest revisions and intervene in a character's journey.
              Shared stories, independent positions. This is not a quest editor.
            </p>
          </div>
          <button id="refresh-quests" phx-click="refresh" class="admin-button admin-secondary">
            <.icon name="hero-arrow-path" class="size-4" /> Refresh state
          </button>
        </header>

        <aside
          :if={@locked}
          id="quest-locked"
          role="status"
          class="rounded-2xl border border-amber-300/25 bg-amber-300/5 p-5 text-sm text-amber-100"
        >
          <p class="font-semibold">Interventions are locked during resolution and review.</p>
          <p class="mt-1 text-amber-100/70">
            Frozen inputs cannot be changed here. Publish the active tick before assigning, replacing, moving or ending quests.
          </p>
          <.link
            id="quest-lock-dashboard"
            navigate={~p"/dashboard"}
            class="mt-3 inline-flex items-center gap-2 text-amber-300 hover:text-amber-100 transition"
          >
            Open tick overview <.icon name="hero-arrow-right" class="size-4" />
          </.link>
        </aside>

        <div class="grid gap-7 lg:grid-cols-[0.8fr_1.2fr]">
          <section class="admin-panel space-y-5">
            <div class="flex items-center justify-between gap-3">
              <h2 class="text-lg font-semibold">
                Characters <span class="text-sm text-slate-500">{@character_count}</span>
              </h2>
              <.link
                id="quest-link-player"
                navigate={~p"/characters"}
                class="text-sm text-amber-300 hover:text-amber-100 transition"
              >Link a player</.link>
            </div>
            <div id="quest-characters" phx-update="stream" class="space-y-3">
              <p id="quest-characters-empty" class="hidden only:block text-sm text-slate-400">
                Link a player on the Characters page before assigning a quest.
              </p>
              <article
                :for={{dom_id, character} <- @streams.characters}
                id={dom_id}
                class={[
                  "rounded-xl border p-4 transition",
                  if(@selected && @selected.id == character.id,
                    do: "border-amber-300/40 bg-amber-300/5",
                    else: "border-white/10 hover:border-white/20"
                  )
                ]}
              >
                <div class="flex items-start justify-between gap-4">
                  <div>
                    <h3 class="font-semibold">{character.name}</h3>
                    <p class="mt-1 text-xs text-slate-500">Discord {character.discord_user_id}</p>
                    <p id={"quest-position-#{character.id}"} class="mt-3 text-sm text-slate-300">
                      <%= if character.progression do %>
                        {character.quest_name} · v{character.revision_number}<span class="block mt-1 font-mono text-xs text-amber-200">{character.progression.node_id}</span>
                      <% else %>
                        No active quest
                      <% end %>
                    </p>
                  </div>
                  <button
                    id={"select-quest-character-#{character.id}"}
                    phx-click="select"
                    phx-value-id={character.id}
                    class="admin-button admin-secondary"
                    aria-label={"Manage quests for #{character.name}"}
                  >Manage</button>
                </div>
              </article>
            </div>
          </section>

          <section class="admin-panel space-y-6">
            <div :if={!@selected} id="quest-select-prompt" class="py-12 text-center">
              <.icon name="hero-map" class="size-10 text-amber-300/50" />
              <h2 class="mt-4 text-xl font-semibold">Choose a character</h2>
              <p class="mt-2 text-sm text-slate-400">
                Inspect their pinned revision, then make an audited intervention.
              </p>
            </div>
            <%= if @selected do %>
              <header
                id="quest-selected-character"
                class="flex flex-wrap items-start justify-between gap-3"
              >
                <div>
                  <p class="text-xs uppercase tracking-widest text-slate-500">Selected character</p>
                  <h2 class="mt-2 text-2xl font-semibold">{@selected.name}</h2>
                </div>
                <.link
                  id="quest-character-profile"
                  navigate={~p"/characters"}
                  class="text-sm text-amber-300 hover:text-amber-100 transition"
                >Manage profile & facts</.link>
              </header>

              <section
                :if={@selected.progression}
                id="quest-current-position"
                class="rounded-xl border border-white/10 bg-white/[0.02] p-4 space-y-3"
              >
                <p class="text-sm font-medium">
                  {@selected.quest_name} · revision {@selected.revision_number}
                </p>
                <p id="quest-current-node" class="font-mono text-xs text-amber-200">
                  {@selected.progression.node_id}
                </p>
                <p
                  id="quest-node-text"
                  class="whitespace-pre-wrap text-sm leading-relaxed text-slate-300"
                >
                  {@current_node["text"]}
                </p>
                <p class="text-xs text-slate-500">
                  Assignment #{@selected.progression.id} · position version {@selected.progression.position_version}
                </p>
              </section>

              <p
                id="quest-intervention-policy"
                class="rounded-xl border border-sky-300/15 bg-sky-300/5 p-4 text-sm leading-relaxed text-slate-300"
              >
                Replacing, ending or changing a node clears this character's open submission.
                Eligibility is recalculated from current facts and clocks. Moving to an ending completes the quest.
                A move to the current node changes nothing. Other characters are unaffected.
              </p>

              <section class="space-y-4">
                <h3 class="text-lg font-semibold">
                  {if @selected.progression, do: "Replace active quest", else: "Assign a quest"}
                </h3>
                <p
                  :if={@revision_options == []}
                  id="quest-content-empty"
                  class="text-sm text-slate-400"
                >
                  No quest content is available yet. Add validated content through the quest domain API; authoring forms are a later milestone.
                </p>
                <.form
                  for={@assignment_form}
                  id="quest-assignment-form"
                  phx-submit={if @selected.progression, do: "swap", else: "assign"}
                  class="admin-form space-y-4"
                >
                  <.input
                    field={@assignment_form[:revision_id]}
                    type="select"
                    label="Quest revision (starts at its start node)"
                    options={@revision_options}
                    prompt="Choose a revision"
                    required
                    disabled={@locked || @revision_options == []}
                    class="admin-input"
                  />
                  <.input
                    id="quest-assignment-reason"
                    field={@assignment_form[:reason]}
                    label="Audit reason"
                    placeholder="Why this character needs this quest"
                    required
                    maxlength="2000"
                    disabled={@locked}
                    class="admin-input"
                  />
                  <button
                    id="quest-assign-submit"
                    disabled={@locked || @revision_options == []}
                    data-confirm={
                      @selected.progression && "Replace the current quest and clear the open choice?"
                    }
                    class="admin-button"
                    phx-disable-with="Saving…"
                  >
                    <.icon name="hero-book-open" class="size-4" /> {if @selected.progression,
                      do: "Replace quest",
                      else: "Assign quest"}
                  </button>
                </.form>
              </section>

              <%= if @selected.progression do %>
                <section class="border-t border-white/10 pt-5 space-y-4">
                  <h3 class="text-lg font-semibold">Move to a node</h3>
                  <.form
                    for={@move_form}
                    id="quest-move-form"
                    phx-submit="move"
                    class="admin-form space-y-4"
                  >
                    <.input
                      field={@move_form[:node_id]}
                      type="select"
                      label="Node in the pinned revision"
                      options={@node_options}
                      required
                      disabled={@locked}
                      class="admin-input"
                    />
                    <.input
                      id="quest-move-reason"
                      field={@move_form[:reason]}
                      label="Audit reason"
                      required
                      maxlength="2000"
                      disabled={@locked}
                      class="admin-input"
                    />
                    <button
                      id="quest-move-submit"
                      disabled={@locked}
                      data-confirm="Change this character's node? An actual move clears their open choice; an ending completes the quest."
                      class="admin-button admin-secondary"
                      phx-disable-with="Moving…"
                    >Move character</button>
                  </.form>
                </section>
                <section class="border-t border-white/10 pt-5 space-y-4">
                  <h3 class="text-lg font-semibold">End active quest</h3>
                  <p class="text-sm text-slate-400">
                    Stop this assignment without marking it completed. It remains recorded in the audit.
                  </p>
                  <.form
                    for={@end_form}
                    id="quest-end-form"
                    phx-submit="end"
                    class="admin-form space-y-4"
                  >
                    <.input
                      id="quest-end-reason"
                      field={@end_form[:reason]}
                      label="Audit reason"
                      required
                      maxlength="2000"
                      disabled={@locked}
                      class="admin-input"
                    />
                    <button
                      id="quest-end-submit"
                      disabled={@locked}
                      data-confirm="End this assignment and clear the character's open choice?"
                      class="admin-button admin-secondary"
                      phx-disable-with="Ending…"
                    >End quest</button>
                  </.form>
                </section>
              <% end %>

              <section class="border-t border-white/10 pt-5 space-y-4">
                <h3 class="text-lg font-semibold">Recent interventions</h3>
                <div id="quest-interventions" phx-update="stream" class="space-y-3">
                  <p id="quest-audit-empty" class="hidden only:block text-sm text-slate-500">
                    No quest interventions recorded for this character.
                  </p>
                  <article
                    :for={{dom_id, audit} <- @streams.interventions}
                    id={dom_id}
                    class="rounded-xl border border-white/10 p-4 space-y-2"
                  >
                    <p class="text-sm font-medium capitalize">
                      {audit.operation}<span class="ml-2 text-xs font-normal text-slate-500">{Calendar.strftime(
                        audit.inserted_at,
                        "%d %b %Y · %H:%M UTC"
                      )}</span>
                    </p>
                    <p class="whitespace-pre-wrap text-sm text-slate-300">{audit.reason}</p>
                    <p class="text-xs text-slate-500">
                      DM {audit.actor_id} · {audit.invalidated_submissions} open choices cleared
                    </p>
                    <p class="font-mono text-xs text-amber-200/80">
                      {if audit.before, do: audit.before["node_id"], else: "unassigned"} → {audit.after[
                        "node_id"
                      ]} · {audit.after["status"]}
                    </p>
                  </article>
                </div>
              </section>
            <% end %>
          </section>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
