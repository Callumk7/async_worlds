defmodule AsyncWorldsWeb.QuestLibraryLive do
  use AsyncWorldsWeb, :live_view
  import AsyncWorldsWeb.AdminComponents
  alias AsyncWorlds.Quests
  alias AsyncWorlds.Quests.{Authoring, Graph}
  alias AsyncWorldsWeb.QuestGraph
  alias Phoenix.LiveView.JS

  @impl true
  def mount(_, _, socket) do
    {:ok,
     assign(socket,
       page_title: "Quest library",
       work: nil,
       recovery: nil,
       recoveries: %{},
       errors: [],
       conflict: false,
       removal: nil
     )}
  end

  @impl true
  def handle_params(params, _, socket) do
    scope = socket.assigns.current_scope

    with {:ok, library} <- Quests.library(scope.campaign, scope.discord_user_id) do
      socket =
        socket
        |> stream(:drafts, library.drafts, reset: true)
        |> stream(:revisions, library.revisions, reset: true)

      socket =
        if params["draft_id"] do
          case Quests.get_working_copy(scope.campaign, scope.discord_user_id, params["draft_id"]) do
            {:ok, work} ->
              socket |> set_loaded_work(work) |> assign(:conflict, false)

            {:error, reason} ->
              socket
              |> assign(work: nil, recovery: nil, conflict: false)
              |> put_flash(:error, error_message(reason))
          end
        else
          assign(socket, work: nil, recovery: nil, conflict: false)
        end

      {:noreply, socket}
    else
      _ -> {:noreply, redirect(socket, to: ~p"/login")}
    end
  end

  @impl true
  def handle_event(event, _, %{assigns: %{work: nil}} = socket) when event not in ["new", "edit"],
    do: {:noreply, put_flash(socket, :error, "Choose a working copy first.")}

  def handle_event("new", _, socket), do: create(socket, nil)
  def handle_event("edit", %{"id" => id}, socket), do: create(socket, id)

  def handle_event("change", %{"quest" => params}, socket) when is_map(params) do
    {:noreply, set_work(socket, Authoring.apply_form(socket.assigns.work, params))}
  end

  def handle_event("add-node", _, socket) do
    work = socket.assigns.work

    if length(work.definition["nodes"]) < 100 do
      definition = Map.update!(work.definition, "nodes", &(&1 ++ [Authoring.new_node()]))
      {:noreply, set_work(socket, %{work | definition: definition})}
    else
      {:noreply, socket}
    end
  end

  def handle_event("add-choice", %{"node" => node_id}, socket) when is_binary(node_id) do
    work = socket.assigns.work

    with i when is_integer(i) <-
           Enum.find_index(work.definition["nodes"], &(&1["id"] == node_id)),
         node = Enum.at(work.definition["nodes"], i),
         false <- node["ending"],
         true <- length(node["choices"]) < 100 do
      nodes =
        List.update_at(work.definition["nodes"], i, fn node ->
          Map.update!(node, "choices", &(&1 ++ [Authoring.new_choice()]))
        end)

      {:noreply, set_work(socket, %{work | definition: Map.put(work.definition, "nodes", nodes)})}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("structure", %{"action" => action, "node" => node_id} = params, socket)
      when action in ["up", "down", "remove"] do
    work = socket.assigns.work
    choice_id = params["choice"]
    inbound = Graph.inbound(work.definition, node_id)

    if action == "remove" and is_nil(choice_id) and inbound != [] do
      {:noreply, assign(socket, removal: %{node: node_id, inbound: inbound})}
    else
      definition = Authoring.restructure(work.definition, action, node_id, choice_id)
      {:noreply, set_work(socket, %{work | definition: definition})}
    end
  end

  def handle_event("confirm-remove", _, %{assigns: %{removal: %{node: id}}} = socket) do
    work = socket.assigns.work
    definition = Authoring.restructure(work.definition, "remove", id)
    {:noreply, set_work(socket, %{work | definition: definition})}
  end

  def handle_event("cancel-remove", _, socket), do: {:noreply, assign(socket, :removal, nil)}

  def handle_event("save", %{"operation" => "release", "quest" => params}, socket)
      when is_map(params),
      do: handle_event("release", %{"quest" => params}, socket)

  def handle_event(action, %{"quest" => params}, socket)
      when action in ["save", "release"] and is_map(params) do
    work = Authoring.apply_form(socket.assigns.work, params)
    scope = socket.assigns.current_scope
    attrs = Map.take(work, [:name, :content_id, :definition])

    result =
      if action == "save",
        do:
          Quests.save_working_copy(
            scope.campaign,
            scope.discord_user_id,
            work.id,
            work.version,
            attrs
          ),
        else:
          Quests.release_working_copy(
            scope.campaign,
            scope.discord_user_id,
            work.id,
            work.version,
            attrs
          )

    socket =
      case result do
        {:ok, %{draft: draft, revision: revision}} ->
          socket
          |> set_loaded_work(draft)
          |> put_flash(
            :info,
            "Released revision #{revision.number}. Existing assignments remain pinned."
          )
          |> push_patch(to: ~p"/quests/library?draft_id=#{draft.id}")

        {:ok, draft} ->
          socket
          |> set_work(draft)
          |> stream_insert(:drafts, draft)
          |> put_flash(:info, "Working copy saved. It is not assignable until released.")

        {:error, {:validation, errors}} ->
          socket |> set_work(work) |> assign(:errors, errors)

        {:error, reason} when reason in [:stale_working_copy, :stale_base_revision] ->
          socket
          |> set_work(work)
          |> retain_recovery(work)
          |> assign(:conflict, true)
          |> put_flash(
            :error,
            "This working copy or its released base changed. Your unsaved work is retained below. Reload to inspect saved content, or recover as a separate quest; no overwrite occurred."
          )

        {:error, reason} ->
          socket |> set_work(work) |> put_flash(:error, library_error(reason))
      end

    {:noreply, socket}
  end

  def handle_event("reload", _, socket) do
    scope = socket.assigns.current_scope

    case Quests.get_working_copy(scope.campaign, scope.discord_user_id, socket.assigns.work.id) do
      {:ok, work} ->
        {:noreply,
         socket
         |> retain_recovery(socket.assigns.work)
         |> set_loaded_work(work)
         |> assign(:conflict, false)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  def handle_event("recover", _, socket) do
    scope = socket.assigns.current_scope
    work = socket.assigns.recovery || socket.assigns.work

    case Quests.recover_working_copy(
           scope.campaign,
           scope.discord_user_id,
           work.id,
           Map.take(work, [:name, :content_id, :definition])
         ) do
      {:ok, copy} ->
        {:noreply,
         socket
         |> assign(
           recoveries: Map.delete(socket.assigns.recoveries, work.id),
           recovery: nil,
           conflict: false
         )
         |> push_patch(to: ~p"/quests/library?draft_id=#{copy.id}")}

      {:error, {:validation, errors}} ->
        {:noreply, assign(socket, :errors, errors)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, library_error(reason))}
    end
  end

  def handle_event(_, _, socket), do: {:noreply, socket}

  defp create(socket, revision_id) do
    scope = socket.assigns.current_scope

    case Quests.create_working_copy(scope.campaign, scope.discord_user_id, revision_id) do
      {:ok, work} -> {:noreply, push_patch(socket, to: ~p"/quests/library?draft_id=#{work.id}")}
      {:error, reason} -> {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  defp retain_recovery(socket, work) do
    recoveries = Map.put_new(socket.assigns.recoveries, work.id, work)
    assign(socket, recoveries: recoveries, recovery: Map.fetch!(recoveries, work.id))
  end

  defp set_loaded_work(socket, work) do
    scope = socket.assigns.current_scope

    base_number =
      if work.base_revision_id do
        case Quests.get_revision(scope.campaign, scope.discord_user_id, work.base_revision_id) do
          {:ok, revision} -> revision.number
          _ -> nil
        end
      end

    socket |> assign(:base_number, base_number) |> set_work(work)
  end

  defp set_work(socket, work) do
    options =
      Enum.with_index(work.definition["nodes"])
      |> Enum.map(fn {node, i} ->
        {"Node #{i + 1}: " <>
           String.slice(node["text"], 0, 45) <> if(node["ending"], do: " (ending)", else: ""),
         node["id"]}
      end)

    assign(socket,
      work: work,
      recovery: Map.get(socket.assigns.recoveries, work.id),
      form: to_form(Authoring.form_params(work), as: :quest),
      node_options: options,
      graph: Graph.analyze(work.definition),
      removal: nil,
      errors: []
    )
  end

  defp destination_options(options, current) do
    if current in Enum.map(options, &elem(&1, 1)) or current in [nil, ""],
      do: options,
      else: [{"Missing: #{current} (repair this link)", current} | options]
  end

  defp library_error(:unsupported_edit),
    do:
      "Unsupported imported fields cannot be changed. Rolled, conditional and effect-bearing choices are read-only."

  defp library_error(:immutable_content_id),
    do: "Released content identity cannot change. Recover as a separate quest instead."

  defp library_error(%Ecto.Changeset{}),
    do:
      "This content identity is already released. Choose a different identity; no changes were written."

  defp library_error(reason), do: error_message(reason)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.navigation active="quests" />
      <section id="quest-library" class="space-y-6">
        <header class="flex flex-wrap justify-between items-end gap-4">
          <div>
            <p class="text-xs uppercase tracking-widest text-amber-300">DM authoring</p><h1 class="text-3xl font-semibold mt-2">
              Quest library
            </h1>
            <p class="mt-3 text-sm text-slate-400">
              Save incomplete work, then release an immutable playable revision. Existing assignments never change.
            </p>
          </div>
          <button id="new-quest" phx-click="new" class="admin-button"><.icon
            name="hero-plus"
            class="size-4"
          /> New quest</button>
          <.link
            id="quest-operations-link"
            navigate={~p"/quests"}
            class="admin-button admin-secondary"
          >Assign released revisions</.link>
        </header>
        <div class="grid gap-6 lg:grid-cols-[0.7fr_1.3fr]">
          <aside class="admin-panel space-y-5">
            <h2 class="font-semibold">Working copies · not playable</h2>
            <div id="library-drafts" phx-update="stream" class="space-y-3">
              <p id="library-drafts-empty" class="hidden only:block text-sm text-slate-400">
                No working copies. Create your first quest or edit a released/imported revision.
              </p>
              <.link
                :for={{id, draft} <- @streams.drafts}
                id={id}
                patch={~p"/quests/library?draft_id=#{draft.id}"}
                class="block rounded-xl border border-white/10 p-3 hover:border-amber-300/40 transition"
              >
                {if draft.name == "", do: "Untitled quest", else: draft.name}<span class="block text-xs text-slate-400">Working version {draft.version}</span>
              </.link>
            </div>
            <h2 class="font-semibold">Released revisions</h2>
            <div id="library-revisions" phx-update="stream" class="space-y-3">
              <p id="library-revisions-empty" class="hidden only:block text-sm text-slate-400">
                Nothing released yet. Complete and release a working copy to enable assignment.
              </p>
              <article
                :for={{id, revision} <- @streams.revisions}
                id={id}
                class="rounded-xl border border-white/10 p-3"
              >
                <p>{revision.name} · v{revision.number}</p><p class="text-xs text-slate-500">
                  {revision.content_id}
                </p>
                <button
                  id={"edit-revision-#{revision.id}"}
                  phx-click="edit"
                  phx-value-id={revision.id}
                  class="mt-2 text-sm text-amber-300"
                >Edit a working copy</button>
              </article>
            </div>
          </aside>
          <section class="admin-panel min-w-0 space-y-5">
            <p :if={!@work} id="library-editor-empty" class="text-slate-400 py-12 text-center">
              Create or resume a working copy to begin.
            </p>
            <%= if @work do %>
              <p id="draft-identity" class="text-xs text-slate-400">
                Working version {@work.version} · Base revision {if @work.base_revision_id,
                  do: "v#{@base_number}",
                  else: "none (new quest)"}
              </p>
              <p id="unsupported-policy" class="rounded-xl bg-sky-300/5 p-4 text-sm text-slate-300">
                Fixed choices only. Imported rolled choices, conditions and effects are preserved intact and read-only. IDs remain stable when reordered. Removing nodes retains inbound references for repair; endings are never converted automatically.
              </p>
              <QuestGraph.graph graph={@graph} definition={@work.definition} />
              <div
                :if={@removal}
                id="node-removal-warning"
                role="alert"
                class="rounded-xl border border-amber-300/30 p-4 space-y-3"
              >
                <p>
                  This node has {length(@removal.inbound)} inbound links. References from retained nodes stay broken for repair and block release.
                </p>
                <ul>
                  <li :for={edge <- @removal.inbound}>{edge.path} → {@removal.node}</li>
                </ul>
                <button id="confirm-remove-node" phx-click="confirm-remove" class="admin-button">Remove and retain broken references</button>
                <button
                  id="cancel-remove-node"
                  phx-click="cancel-remove"
                  class="admin-button admin-secondary"
                >Cancel</button>
              </div>
              <div
                :if={@conflict || @recovery}
                id="draft-conflict"
                class="rounded-xl border border-amber-300/30 p-4 space-y-3"
              >
                <p class="text-sm">
                  Unsaved work is retained in this tab. Reload does not erase the recovery copy. Recovery creates a separate content identity, not a replacement revision.
                </p>
                <button id="reload-draft" phx-click="reload" class="admin-button admin-secondary">Inspect saved copy</button>
                <button id="recover-draft" phx-click="recover" class="admin-button admin-secondary">Recover work as separate quest</button>
              </div>
              <ul
                :if={@errors != []}
                id="draft-errors"
                role="alert"
                class="text-sm text-rose-300 space-y-2"
              >
                <li :for={{path, message} <- @errors}>
                  <a
                    href={"##{QuestGraph.target(path, @work.definition)}"}
                    phx-click={JS.focus(to: "##{QuestGraph.target(path, @work.definition)}")}
                    class="underline break-all"
                  ><strong>{path}</strong>: {message}</a>
                </li>
              </ul>
              <.form
                for={@form}
                id="quest-editor-form"
                phx-change="change"
                phx-submit="save"
                class="admin-form space-y-5"
              >
                <.input field={@form[:name]} id="quest-name" label="Quest name" class="admin-input" />
                <.input
                  field={@form[:content_id]}
                  id="quest-content-id"
                  label="Content identity (stable library key)"
                  readonly={@work.quest_id != nil}
                  class="admin-input"
                />
                <.input
                  field={@form[:start_node]}
                  id="quest-start-node"
                  type="select"
                  label="Start node"
                  prompt={
                    if(@work.definition["start_node"] == "", do: "Choose a start node", else: nil)
                  }
                  options={destination_options(@node_options, @work.definition["start_node"])}
                  class="admin-input"
                />
                <%= for {node, i} <- Enum.with_index(@work.definition["nodes"]) do %>
                  <section
                    id={"editor-node-#{i}"}
                    class="rounded-xl border border-white/10 p-4 space-y-4"
                  >
                    <h3 class="font-semibold">Node {i + 1}</h3>
                    <div class="flex gap-3 text-xs">
                      <button
                        :for={action <- ["up", "down"]}
                        id={"move-node-#{i}-#{action}"}
                        type="button"
                        phx-click="structure"
                        phx-value-action={action}
                        phx-value-node={node["id"]}
                        class="admin-button admin-secondary"
                      >Move {action}</button>
                      <button
                        id={"remove-node-#{i}"}
                        type="button"
                        phx-click="structure"
                        phx-value-action="remove"
                        phx-value-node={node["id"]}
                        disabled={length(@work.definition["nodes"]) == 1}
                        class="admin-button admin-secondary"
                      >Remove node</button>
                    </div>
                    <.input
                      field={@form["node_#{i}_text"]}
                      id={"node-#{i}-text"}
                      type="textarea"
                      label="Narrative text"
                      class="admin-input"
                    />
                    <.input
                      field={@form["node_#{i}_ending"]}
                      id={"node-#{i}-ending"}
                      type="select"
                      label="Node type"
                      options={[
                        {"Continue with choices", "false"},
                        {"Explicit ending (must have no choices)", "true"}
                      ]}
                      disabled={!Enum.all?(node["choices"], &Authoring.editable?/1)}
                      class="admin-input"
                    />
                    <%= for {choice, j} <- Enum.with_index(node["choices"]) do %>
                      <div
                        id={"editor-choice-#{i}-#{j}"}
                        tabindex="-1"
                        class="border-t border-white/10 pt-4 space-y-3"
                      >
                        <div class="flex gap-3 text-xs">
                          <button
                            :for={action <- ["up", "down", "remove"]}
                            id={"choice-#{i}-#{j}-#{action}"}
                            type="button"
                            phx-click="structure"
                            phx-value-action={action}
                            phx-value-node={node["id"]}
                            phx-value-choice={choice["id"]}
                            class="admin-button admin-secondary"
                          >{action} choice</button>
                        </div>
                        <%= if Authoring.editable?(choice) do %>
                          <p class="text-xs text-slate-500">Choice {j + 1} · fixed outcome</p>
                          <.input
                            field={@form["node_#{i}_choice_#{j}_label"]}
                            id={"choice-#{i}-#{j}-label"}
                            label="Choice label"
                            class="admin-input"
                          />
                          <.input
                            field={@form["node_#{i}_choice_#{j}_text"]}
                            id={"choice-#{i}-#{j}-text"}
                            type="textarea"
                            label="Outcome text"
                            class="admin-input"
                          />
                          <.input
                            field={@form["node_#{i}_choice_#{j}_destination"]}
                            id={"choice-#{i}-#{j}-destination"}
                            type="select"
                            prompt="Choose a destination"
                            label="Destination"
                            options={
                              destination_options(
                                @node_options,
                                choice["outcomes"]["fixed"]["next_node"]
                              )
                            }
                            class="admin-input"
                          />
                        <% else %>
                          <span
                            id={"choice-#{i}-#{j}-destination"}
                            tabindex="-1"
                            class="block text-xs text-slate-400"
                          >Destinations: {Enum.map_join(choice["outcomes"], ", ", fn {kind, outcome} ->
                            "#{kind} → #{outcome["next_node"]}"
                          end)}</span>
                          <p id={"protected-choice-#{i}-#{j}"} class="text-sm text-sky-200">
                            {choice["label"]} · {choice["mode"]} · read-only imported configuration (conditions/effects preserved)
                          </p>
                        <% end %>
                      </div>
                    <% end %>
                    <button
                      id={"add-choice-#{i}"}
                      type="button"
                      phx-click="add-choice"
                      phx-value-node={node["id"]}
                      disabled={node["ending"] || length(node["choices"]) >= 100}
                      class="admin-button admin-secondary"
                    >Add ordered fixed choice</button>
                  </section>
                <% end %>
                <button
                  id="add-quest-node"
                  disabled={length(@work.definition["nodes"]) >= 100}
                  type="button"
                  phx-click="add-node"
                  class="admin-button admin-secondary"
                >Add node</button>
                <div class="flex flex-wrap gap-3 border-t border-white/10 pt-5">
                  <button
                    id="save-quest-draft"
                    class="admin-button admin-secondary"
                    phx-disable-with="Saving…"
                  >Save working copy</button>
                  <button
                    id="release-quest-revision"
                    name="operation"
                    value="release"
                    class="admin-button"
                    phx-disable-with="Validating…"
                  >Validate & release revision</button>
                </div>
              </.form>
            <% end %>
          </section>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
