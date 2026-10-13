defmodule AsyncWorldsWeb.CharacterLive do
  use AsyncWorldsWeb, :live_view
  import AsyncWorldsWeb.AdminComponents
  alias AsyncWorlds.{Characters, Quests}
  alias AsyncWorlds.Characters.Flags
  alias AsyncWorlds.Characters.Character

  @impl true
  def mount(_, _, socket) do
    {:ok, socket |> assign(page_title: "Characters") |> new_form() |> refresh()}
  end

  @impl true
  def handle_params(params, _, socket) do
    if params["character_id"] do
      handle_event("edit", %{"id" => params["character_id"]}, socket)
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("new", _, socket), do: {:noreply, new_form(socket)}

  def handle_event("edit", %{"id" => id}, socket) do
    case Characters.get_character(campaign(socket), actor(socket), id) do
      {:ok, character} -> {:noreply, edit_form(socket, character)}
      {:error, reason} -> {:noreply, socket |> new_form() |> failure(reason)}
    end
  end

  def handle_event("save", %{"character" => params}, socket) do
    # The profile editor cannot submit flags or campaign ownership.
    attrs = Map.take(params, ["name", "discord_user_id"])

    result =
      if socket.assigns.editing do
        Characters.update_character(
          campaign(socket),
          actor(socket),
          socket.assigns.editing.id,
          attrs,
          expected_character: socket.assigns.editing
        )
      else
        Characters.create_character(campaign(socket), actor(socket), attrs)
      end

    case result do
      {:ok, character} ->
        {:noreply,
         socket |> edit_form(character) |> refresh() |> put_flash(:info, "Character saved.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}

      {:error, reason} ->
        {:noreply, failure(socket, reason)}
    end
  end

  def handle_event("set_flag", %{"flag" => params}, socket) do
    result =
      with %Character{} = character <- socket.assigns.editing,
           params = pinned_flag_params(socket, params),
           {:ok, flag} <- Flags.parse(params) do
        Characters.set_flag(campaign(socket), actor(socket), character.id, params["key"], flag,
          expected_character: character
        )
      else
        {:error, reason} -> {:error, reason}
        _ -> {:error, :invalid_flag}
      end

    {:noreply, flag_result(socket, result)}
  end

  def handle_event("clear_flag", %{"key" => key}, socket) do
    result =
      if socket.assigns.editing,
        do:
          Characters.clear_flag(campaign(socket), actor(socket), socket.assigns.editing.id, key,
            expected_character: socket.assigns.editing
          ),
        else: {:error, :not_found}

    {:noreply, flag_result(socket, result)}
  end

  def handle_event("flag_type", %{"flag" => params}, socket) do
    params = pinned_flag_params(socket, params)

    {:noreply,
     assign(socket,
       flag_form: params_form(params, [:key, :type, :value, :player_visible], as: :flag)
     )}
  end

  def handle_event("edit_flag", %{"key" => key}, socket) do
    flag = socket.assigns.editing && socket.assigns.editing.flags[key]

    if flag do
      params =
        Map.merge(flag, %{
          "key" => key,
          "value" => to_string(flag["value"]),
          "player_visible" => to_string(flag["player_visible"])
        })

      {:noreply,
       assign(socket,
         editing_flag: key,
         flag_form: params_form(params, [:key, :type, :value, :player_visible], as: :flag)
       )}
    else
      {:noreply, failure(socket, :not_found)}
    end
  end

  def handle_event("new_flag", _, socket),
    do: {:noreply, edit_form(socket, socket.assigns.editing)}

  def handle_event(_, _, socket), do: {:noreply, failure(socket, :not_found)}

  defp flag_result(socket, {:ok, character}),
    do: socket |> edit_form(character) |> refresh() |> put_flash(:info, "Flags saved.")

  defp flag_result(socket, {:error, reason}), do: failure(socket, reason)

  defp pinned_flag_params(socket, params) do
    case socket.assigns.editing_flag do
      nil ->
        params

      key ->
        params
        |> Map.put("key", key)
        |> preserve_line_endings(socket.assigns.editing.flags[key])
    end
  end

  # Browsers normalize textarea CR/CRLF to LF. Visibility/type events must not
  # rewrite an otherwise unchanged imported string just because of that normalization.
  defp preserve_line_endings(
         %{"type" => "string", "value" => value} = params,
         %{"type" => "string", "value" => original}
       )
       when is_binary(value) do
    normalized = original |> String.replace("\r\n", "\n") |> String.replace("\r", "\n")
    if value == normalized, do: Map.put(params, "value", original), else: params
  end

  defp preserve_line_endings(params, _), do: params

  defp campaign(socket), do: socket.assigns.current_scope.campaign
  defp actor(socket), do: socket.assigns.current_scope.discord_user_id

  defp failure(socket, reason)
       when reason in [:unauthorized, :stale_campaign, :invalid_campaign] do
    cleared = socket |> new_form() |> stream(:characters, [], reset: true)
    if cleared.redirected, do: cleared, else: redirect(cleared, to: ~p"/login")
  end

  defp failure(socket, reason), do: put_flash(socket, :error, error_message(reason))

  defp refresh(%{redirected: redirect} = socket) when not is_nil(redirect), do: socket

  defp refresh(socket) do
    case Characters.list_characters(campaign(socket), actor(socket)) do
      {:ok, characters} -> stream(socket, :characters, characters, reset: true)
      {:error, reason} -> socket |> stream(:characters, [], reset: true) |> failure(reason)
    end
  end

  defp new_form(socket), do: edit_form(socket, nil)

  defp edit_form(socket, character) do
    state =
      if character,
        do: Quests.management_state(campaign(socket), actor(socket), character.id),
        else: {:ok, %{selected: nil, audits: []}}

    case state do
      {:ok, state} -> apply_form(socket, character, state.selected, state.audits)
      {:error, reason} -> socket |> new_form() |> failure(reason)
    end
  end

  defp apply_form(socket, character, connected, audits) do
    socket = stream(socket, :interventions, audits, reset: true)

    assign(socket,
      connected: connected,
      editing_flag: nil,
      editing: character,
      form: to_form(Character.changeset(character || %Character{}, %{})),
      flag_form:
        params_form(
          %{"key" => "", "type" => "boolean", "value" => "true", "player_visible" => "false"},
          [:key, :type, :value, :player_visible],
          as: :flag
        )
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.navigation active="characters" />
      <section id="character-management" class="space-y-7">
        <header>
          <p class="text-xs uppercase tracking-widest text-amber-300">Campaign cast</p>
          <h1 class="mt-2 text-4xl font-semibold tracking-tight">Characters</h1>
          <p class="mt-3 text-sm text-slate-400">
            Link one character per Discord player, or leave the account blank for a DM-controlled character.
            Facts stay private unless explicitly shared.
          </p>
        </header>
        <div class="grid gap-7 lg:grid-cols-2">
          <section class="admin-panel space-y-5">
            <div class="flex justify-between items-center">
              <h2 class="text-xl font-semibold">
                {if @editing, do: "Edit character", else: "Create a character"}
              </h2>
              <button id="new-character" phx-click="new" class="admin-button admin-secondary">New</button>
            </div>
            <.form for={@form} id="character-form" phx-submit="save" class="admin-form space-y-4">
              <.input
                field={@form[:name]}
                label="Character name"
                required
                maxlength="200"
                class="admin-input"
              />
              <.input
                field={@form[:discord_user_id]}
                label="Discord user ID (optional; blank means DM-controlled)"
                class="admin-input"
              />
              <p :if={@editing} id="ownership-policy" class="text-sm text-slate-400">
                Changing or clearing Discord ownership clears this character's open submission.
                The new owner receives future personal messages; the quest remains pinned. Other characters are unaffected.
              </p>
              <button
                id="save-character"
                class="admin-button"
                phx-disable-with="Saving…"
                data-confirm={
                  @editing &&
                    "Save profile? If ownership changes, the open submission is cleared and future messages go to the new owner (or DM)."
                }
              >Save character</button>
            </.form>
            <section
              :if={@connected}
              id="connected-character"
              class="border-t border-white/10 pt-5 space-y-4"
            >
              <h2 class="text-lg font-semibold">Connected journey</h2>
              <p id="connected-identity" class="text-sm text-slate-400">
                {if @editing.discord_user_id,
                  do: "Discord #{@editing.discord_user_id}",
                  else: "DM-controlled"}
              </p>
              <p id="connected-position" class="text-sm text-slate-300">
                <%= if @connected.progression do %>
                  {@connected.quest_name} · pinned revision {@connected.revision_number} · {@connected.progression.node_id} · {@connected.progression.status}
                <% else %>
                  No active quest
                <% end %>
              </p>
              <.link
                id="connected-quest-operations"
                navigate={~p"/quests?character_id=#{@editing.id}"}
                class="admin-button admin-secondary"
              >Quest operations</.link>
              <.link
                id="connected-quest-content"
                navigate={~p"/quests/library"}
                class="admin-button admin-secondary"
              >Quest content</.link>
              <h3 class="text-sm font-semibold">Recent interventions (DM only)</h3>
              <div id="character-interventions" phx-update="stream" class="space-y-2">
                <p id="character-audit-empty" class="hidden only:block text-sm text-slate-500">
                  No interventions yet.
                </p>
                <article
                  :for={{id, audit} <- @streams.interventions}
                  id={id}
                  class="rounded-xl border border-white/10 p-3 text-sm text-slate-300"
                >
                  <p>
                    {audit.operation} · {Calendar.strftime(audit.inserted_at, "%d %b %Y · %H:%M UTC")}
                  </p>
                  <p class="whitespace-pre-wrap">{audit.reason}</p>
                  <p class="text-xs text-slate-500">
                    DM {audit.actor_id} · {audit.invalidated_submissions} open choices cleared
                  </p>
                </article>
              </div>
            </section>
            <section :if={@editing} id="flag-editor" class="border-t border-white/10 pt-5 space-y-4">
              <h2 class="text-lg font-semibold">Typed facts</h2>
              <p class="text-sm text-slate-400">
                Choose a type and enter an ordinary value. Strings are stored exactly as typed, including quotes.
                Hidden facts stay DM-only; visible facts are shared only with this character's owner.
              </p>
              <.form
                for={@flag_form}
                id="flag-form"
                phx-submit="set_flag"
                phx-change="flag_type"
                class="admin-form space-y-4"
              >
                <.input
                  field={@flag_form[:key]}
                  label="Key (lowercase_with_underscores)"
                  required
                  readonly={@editing_flag != nil}
                  class="admin-input"
                />
                <.flag_inputs form={@flag_form} />
                <button
                  id="new-flag"
                  type="button"
                  phx-click="new_flag"
                  class="admin-button admin-secondary"
                >New fact</button>
                <button id="save-flag" class="admin-button" phx-disable-with="Saving…">Set flag</button>
              </.form>
              <div id="character-flags" class="space-y-2">
                <div
                  :for={{key, flag} <- Enum.sort(@editing.flags)}
                  id={"flag-#{key}"}
                  class="rounded-xl border border-white/10 p-3 flex justify-between gap-3"
                >
                  <p class="text-sm">
                    <strong>{key}</strong>
                    · {flag["type"]} ·
                    <span id={"flag-value-#{key}"} class="whitespace-pre-wrap">{to_string(
                      flag["value"]
                    )}</span><span class="block text-xs text-slate-400">{if flag[
                                                                              "player_visible"
                                                                            ],
                                                                            do: "Visible to owner",
                                                                            else: "Hidden"}</span>
                  </p>
                  <button
                    id={"edit-flag-#{key}"}
                    phx-click="edit_flag"
                    phx-value-key={key}
                    class="text-sm text-amber-300 hover:text-amber-100 transition"
                  >Edit</button>
                  <button
                    id={"clear-flag-#{key}"}
                    phx-click="clear_flag"
                    phx-value-key={key}
                    class="text-sm text-rose-300 hover:text-rose-100 transition"
                  >Clear</button>
                </div>
              </div>
            </section>
          </section>
          <section class="admin-panel">
            <h2 class="mb-5 text-xl font-semibold">Campaign characters</h2>
            <div id="managed-characters" phx-update="stream" class="space-y-3">
              <p id="characters-empty" class="hidden only:block text-sm text-slate-400">
                Create the first character to get started.
              </p>
              <article
                :for={{dom_id, character} <- @streams.characters}
                id={dom_id}
                class="rounded-xl border border-white/10 p-4 flex justify-between gap-4 items-center"
              >
                <div>
                  <h3 class="font-semibold">{character.name}</h3><p
                    id={"character-destination-#{character.id}"}
                    class="text-xs text-slate-400 mt-1"
                  >
                    ID {character.id} · {if character.discord_user_id,
                      do: "Discord #{character.discord_user_id}",
                      else: "DM-controlled · personal messages go to the DM"}
                  </p>
                </div>
                <div class="flex flex-wrap gap-2">
                  <button
                    id={"edit-character-#{character.id}"}
                    phx-click="edit"
                    phx-value-id={character.id}
                    class="admin-button admin-secondary"
                  >Edit</button>
                  <.link
                    id={"character-quests-#{character.id}"}
                    navigate={~p"/quests?character_id=#{character.id}"}
                    class="admin-button admin-secondary"
                  >Quests</.link>
                </div>
              </article>
            </div>
          </section>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
