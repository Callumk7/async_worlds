defmodule AsyncWorldsWeb.MembershipPanel do
  @moduledoc false
  use AsyncWorldsWeb, :html

  import Phoenix.LiveView, only: [stream: 4, stream_insert: 3, put_flash: 3]
  alias AsyncWorlds.{Characters, Factions, Memberships}
  alias AsyncWorlds.Factions.Membership

  def reset(socket) do
    socket
    |> assign(
      membership_entity: nil,
      membership_type: nil,
      membership_options: [],
      membership_form: to_form(%{"target_id" => "", "role" => ""}, as: :membership),
      membership_error: nil,
      membership_target: ""
    )
    |> stream(:memberships, [], reset: true)
  end

  def load(socket, type, entity) do
    scope = socket.assigns.current_scope

    with {:ok, memberships} <- list(scope, type, entity.id),
         {:ok, choices} <- choices(scope, type) do
      {:ok,
       socket
       |> reset()
       |> assign(
         membership_entity: entity,
         membership_type: type,
         membership_options: Enum.map(choices, &{&1.name, &1.id})
       )
       |> stream(:memberships, Enum.map(memberships, &row/1), reset: true)}
    end
  end

  def handle(socket, event, params) do
    with %{id: id} <- socket.assigns.membership_entity,
         type = socket.assigns.membership_type,
         {:ok, current} <- list(socket.assigns.current_scope, type, id) do
      result = mutate(socket.assigns.current_scope, type, id, current, event, params)
      result(socket, result, event, params, current)
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp mutate(scope, type, id, _current, "membership_join", %{"membership" => params})
       when is_map(params) do
    attrs = Map.take(params, ["role"])

    if type == :faction,
      do: Memberships.join(scope, params["target_id"], id, attrs),
      else: Memberships.join(scope, id, params["target_id"], attrs)
  end

  defp mutate(scope, _type, _id, current, event, %{"id" => id} = params)
       when event in ["membership_role", "membership_leave"] and (is_binary(id) or is_integer(id)) do
    # A campaign-valid ID is not sufficient: it must belong to this selected panel.
    case Enum.find(current, &(to_string(&1.id) == to_string(id))) do
      nil ->
        {:error, :not_found}

      membership ->
        if event == "membership_leave",
          do: Memberships.leave(scope, membership.id),
          else: edit_role(scope, membership.id, params["membership"])
    end
  end

  defp mutate(_, _, _, _, _, _), do: {:error, :not_found}

  defp edit_role(scope, id, params) when is_map(params),
    do: Memberships.edit_role(scope, id, Map.take(params, ["role"]))

  defp edit_role(_, _, _), do: {:error, :not_found}

  defp result(socket, {:ok, _}, _event, _params, _current) do
    with {:ok, updated} <-
           load(socket, socket.assigns.membership_type, socket.assigns.membership_entity) do
      {:ok, put_flash(updated, :info, "Membership saved.")}
    end
  end

  defp result(socket, {:error, %Ecto.Changeset{} = changeset}, event, params, current) do
    socket =
      assign(socket,
        membership_error:
          "Membership could not be saved. Check the role and whether this character already belongs to the faction."
      )

    socket =
      if event == "membership_join" do
        form = to_form(changeset, as: :membership)
        # The target is a selector, not an editable endpoint on the membership schema.
        assign(socket,
          membership_form: form,
          membership_target: get_in(params, ["membership", "target_id"])
        )
      else
        membership = Enum.find(current, &(to_string(&1.id) == to_string(params["id"])))

        stream_insert(
          socket,
          :memberships,
          Map.put(membership, :role_form, to_form(changeset, as: :membership))
        )
      end

    {:ok, socket}
  end

  defp result(_socket, {:error, reason}, _, _, _), do: {:error, reason}

  defp row(membership),
    do:
      Map.put(
        membership,
        :role_form,
        to_form(Membership.changeset(membership, %{}), as: :membership)
      )

  defp list(scope, :faction, id), do: Memberships.list_faction_members(scope, id)
  defp list(scope, :character, id), do: Memberships.list_character_affiliations(scope, id)

  defp choices(scope, :faction),
    do: Characters.list_characters(scope.campaign, scope.discord_user_id)

  defp choices(scope, :character), do: Factions.list_factions(scope)

  attr :type, :atom, required: true
  attr :form, :any, required: true
  attr :options, :list, required: true
  attr :memberships, :any, required: true
  attr :error, :string, default: nil
  attr :target, :any, default: ""

  def panel(assigns) do
    ~H"""
    <section id="membership-panel" class="border-t border-white/10 pt-5 space-y-5">
      <div class="flex items-center justify-between gap-3">
        <h2 class="text-lg font-semibold">
          {if @type == :faction, do: "Faction members", else: "Faction affiliations"}
        </h2>
        <span class="rounded-full border border-amber-300/20 px-2 py-1 text-xs text-amber-300">DM only</span>
      </div>
      <p class="text-sm text-slate-400">
        Roles are descriptive only. Memberships do not change ownership, facts or quests.
      </p>
      <p :if={@error} id="membership-error" role="alert" class="text-sm text-rose-300">{@error}</p>
      <.form
        for={@form}
        id="membership-join-form"
        phx-submit="membership_join"
        class="admin-form space-y-3"
      >
        <.input
          type="select"
          name="membership[target_id]"
          id="membership-target"
          value={@target}
          options={@options}
          prompt={if @type == :faction, do: "Choose a character", else: "Choose a faction"}
          label={if @type == :faction, do: "Character", else: "Faction"}
          required
          class="admin-input"
        />
        <.input field={@form[:role]} label="Role (optional)" maxlength="200" class="admin-input" />
        <button id="membership-join" class="admin-button" phx-disable-with="Joining…">Add membership</button>
      </.form>
      <div id="memberships" phx-update="stream" class="space-y-3">
        <p id="memberships-empty" class="hidden only:block text-sm text-slate-400">
          No current memberships.
        </p>
        <article
          :for={{dom_id, membership} <- @memberships}
          id={dom_id}
          class="rounded-xl border border-white/10 p-4 space-y-3"
        >
          <h3 class="font-semibold break-words">
            {if @type == :faction, do: membership.character.name, else: membership.faction.name}
          </h3>
          <.form
            for={membership.role_form}
            id={"membership-role-form-#{membership.id}"}
            phx-submit="membership_role"
            phx-value-id={membership.id}
            class="admin-form space-y-3"
          >
            <.input
              field={membership.role_form[:role]}
              id={"membership-role-#{membership.id}"}
              label="Role (optional)"
              maxlength="200"
              class="admin-input"
            />
            <div class="flex flex-wrap gap-2">
              <button
                id={"membership-save-#{membership.id}"}
                class="admin-button admin-secondary"
                phx-disable-with="Saving…"
              >Save role</button>
              <button
                id={"membership-leave-#{membership.id}"}
                type="button"
                phx-click="membership_leave"
                phx-value-id={membership.id}
                data-confirm="Remove this membership? Its history will be retained."
                phx-disable-with="Removing…"
                class="admin-button admin-secondary text-rose-300 transition hover:text-rose-100"
              >Leave faction</button>
            </div>
          </.form>
        </article>
      </div>
    </section>
    """
  end
end
