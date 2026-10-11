defmodule AsyncWorldsWeb.CharacterLive do
  use AsyncWorldsWeb, :live_view
  import AsyncWorldsWeb.AdminComponents
  alias AsyncWorlds.Characters
  alias AsyncWorlds.Characters.Character

  @impl true
  def mount(_, _, socket) do
    {:ok, socket |> assign(page_title: "Characters") |> new_form() |> refresh()}
  end

  @impl true
  def handle_event("new", _, socket), do: {:noreply, new_form(socket)}

  def handle_event("edit", %{"id" => id}, socket) do
    case Characters.get_character(campaign(socket), actor(socket), id) do
      {:ok, character} -> {:noreply, edit_form(socket, character)}
      {:error, reason} -> {:noreply, failure(socket, reason)}
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
          attrs
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
           json when is_binary(json) <- params["value"],
           {:ok, value} <- Jason.decode(json),
           visible when visible in ["true", "false"] <- params["player_visible"] do
        Characters.set_flag(campaign(socket), actor(socket), character.id, params["key"], %{
          "type" => params["type"],
          "value" => value,
          "player_visible" => visible == "true"
        })
      else
        _ -> {:error, :invalid_flag}
      end

    {:noreply, flag_result(socket, result)}
  end

  def handle_event("clear_flag", %{"key" => key}, socket) do
    result =
      if socket.assigns.editing,
        do:
          Characters.clear_flag(campaign(socket), actor(socket), socket.assigns.editing.id, key),
        else: {:error, :not_found}

    {:noreply, flag_result(socket, result)}
  end

  def handle_event(_, _, socket), do: {:noreply, failure(socket, :not_found)}

  defp flag_result(socket, {:ok, character}),
    do: socket |> edit_form(character) |> refresh() |> put_flash(:info, "Flags saved.")

  defp flag_result(socket, {:error, _}),
    do:
      put_flash(
        socket,
        :error,
        "Flag not saved. Check type, JSON value and current authorization."
      )

  defp campaign(socket), do: socket.assigns.current_scope.campaign
  defp actor(socket), do: socket.assigns.current_scope.discord_user_id
  defp failure(socket, reason), do: put_flash(socket, :error, error_message(reason))

  defp refresh(socket) do
    case Characters.list_characters(campaign(socket), actor(socket)) do
      {:ok, characters} -> stream(socket, :characters, characters, reset: true)
      {:error, reason} -> socket |> stream(:characters, [], reset: true) |> failure(reason)
    end
  end

  defp new_form(socket), do: edit_form(socket, nil)

  defp edit_form(socket, character) do
    assign(socket,
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
            One character per Discord player. Facts stay private unless explicitly shared.
          </p>
        </header>
        <div class="grid gap-7 lg:grid-cols-2">
          <section class="admin-panel space-y-5">
            <div class="flex justify-between items-center">
              <h2 class="text-xl font-semibold">
                {if @editing, do: "Edit character", else: "Link a player"}
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
                label="Discord user ID"
                required
                class="admin-input"
              />
              <button id="save-character" class="admin-button" phx-disable-with="Saving…">Save character</button>
            </.form>
            <section :if={@editing} id="flag-editor" class="border-t border-white/10 pt-5 space-y-4">
              <h2 class="text-lg font-semibold">Typed facts</h2>
              <p class="text-sm text-slate-400">
                Value is JSON: true / false, a whole number, or a quoted string. Saving an existing key replaces it.
              </p>
              <.form
                for={@flag_form}
                id="flag-form"
                phx-submit="set_flag"
                class="admin-form space-y-4"
              >
                <.input
                  field={@flag_form[:key]}
                  label="Key (lowercase_with_underscores)"
                  required
                  class="admin-input"
                />
                <.input
                  field={@flag_form[:type]}
                  type="select"
                  label="Type"
                  options={["boolean", "integer", "string"]}
                  class="admin-input"
                />
                <.input field={@flag_form[:value]} label="JSON value" required class="admin-input" />
                <.input
                  field={@flag_form[:player_visible]}
                  type="select"
                  label="Player visibility"
                  options={["Hidden (DM only)": "false", "Visible to owner": "true"]}
                  class="admin-input"
                />
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
                    · {flag["type"]} · {Jason.encode!(flag["value"])}<span class="block text-xs text-slate-400">{if flag[
                                                                                                                      "player_visible"
                                                                                                                    ],
                                                                                                                    do:
                                                                                                                      "Visible to owner",
                                                                                                                    else:
                                                                                                                      "Hidden"}</span>
                  </p>
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
            <h2 class="mb-5 text-xl font-semibold">Linked players</h2>
            <div id="managed-characters" phx-update="stream" class="space-y-3">
              <p id="characters-empty" class="hidden only:block text-sm text-slate-400">
                Link the first player to get started.
              </p>
              <article
                :for={{dom_id, character} <- @streams.characters}
                id={dom_id}
                class="rounded-xl border border-white/10 p-4 flex justify-between gap-4 items-center"
              >
                <div>
                  <h3 class="font-semibold">{character.name}</h3><p class="text-xs text-slate-400 mt-1">
                    Discord {character.discord_user_id}
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
