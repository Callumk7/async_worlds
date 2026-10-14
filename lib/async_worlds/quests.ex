defmodule AsyncWorlds.Quests do
  @moduledoc "Freshly authorized campaign-owned quest authoring and DM progression management."
  import Ecto.Query
  import Ecto.Changeset
  alias AsyncWorlds.{Campaigns, Clocks, Repo}
  alias AsyncWorlds.Campaigns.Campaign
  alias AsyncWorlds.Characters.Character
  alias AsyncWorlds.Discord.Snowflake

  alias AsyncWorlds.Quests.{
    Definition,
    Intervention,
    Progression,
    Quest,
    Revision,
    Rules,
    Submission,
    Submissions
  }

  alias AsyncWorlds.Ticks.Tick

  alias AsyncWorlds.Quests.{Authoring, WorkingCopy}

  @doc "Released campaign quests for clock availability triggers (not assignments)."
  def trigger_targets(campaign, dm_id) do
    manage(campaign, dm_id, fn current ->
      Repo.all(from q in Quest, where: q.campaign_id == ^current.id, order_by: [q.name, q.id])
    end)
  end

  @doc "Campaign-scoped library, including incomplete, unassignable working copies."
  def library(campaign, dm_id) do
    manage(campaign, dm_id, fn current ->
      %{
        clocks: Clocks.list_clocks(current.id),
        drafts:
          Repo.all(
            from d in WorkingCopy,
              where: d.campaign_id == ^current.id,
              order_by: [desc: d.updated_at, desc: d.id]
          ),
        revisions:
          Repo.all(
            from r in Revision,
              join: q in Quest,
              on: q.id == r.quest_id,
              where: r.campaign_id == ^current.id,
              order_by: [q.name, desc: r.number],
              select: %{id: r.id, name: q.name, content_id: q.content_id, number: r.number}
          )
      }
    end)
  end

  def create_working_copy(campaign, dm_id, revision_id \\ nil) do
    manage(campaign, dm_id, fn current ->
      attrs =
        if revision_id do
          revision = fetch!(Revision, current.id, revision_id)
          quest = fetch!(Quest, current.id, revision.quest_id)

          %{
            quest_id: quest.id,
            base_revision_id: revision.id,
            name: quest.name,
            content_id: quest.content_id,
            definition: revision.definition
          }
        else
          %{
            name: "",
            content_id: new_content_id(),
            definition: Authoring.new_definition()
          }
        end

      attrs =
        attrs
        |> Map.put(:campaign_id, current.id)
        |> Map.put(:source_definition, attrs.definition)

      Repo.insert!(struct(WorkingCopy, attrs))
    end)
  end

  def get_working_copy(campaign, dm_id, id),
    do: manage(campaign, dm_id, fn current -> fetch!(WorkingCopy, current.id, id) end)

  @doc "Save incomplete content. Version and latest base are checked under the same campaign lock as imports."
  def save_working_copy(campaign, dm_id, id, version, attrs) do
    manage(campaign, dm_id, fn current ->
      draft = editable_work!(current, id, version)
      update_work!(draft, attrs)
    end)
  end

  @doc "Validate and append atomically; failure leaves both draft and released library unchanged."
  def release_working_copy(campaign, dm_id, id, version, attrs) do
    manage(campaign, dm_id, fn current ->
      draft = editable_work!(current, id, version)
      draft = update_work!(draft, attrs)
      errors = Definition.errors(draft.definition, clock_map(current.id))

      errors =
        if Definition.text?(draft.name) and byte_size(draft.name) <= 200,
          do: errors,
          else: [{"name", "Name is required (maximum 200 bytes)"} | errors]

      errors =
        if Definition.id?(draft.content_id),
          do: errors,
          else: [
            {"content_id",
             "Content identity is invalid; recover this working copy as a separate quest"}
            | errors
          ]

      if errors != [], do: Repo.rollback({:validation, errors})

      quest =
        if draft.quest_id do
          fetch!(Quest, current.id, draft.quest_id) |> change(name: draft.name) |> Repo.update!()
        else
          %Quest{campaign_id: current.id, name: draft.name, content_id: draft.content_id}
          |> change()
          |> unique_constraint([:campaign_id, :content_id])
          |> Repo.insert()
          |> persist()
        end

      revision = append!(current.id, quest.id, draft.definition)
      draft = Repo.update!(change(draft, quest_id: quest.id, base_revision_id: revision.id))
      %{draft: draft, revision: revision}
    end)
  end

  @doc "Explicit conflict recovery: fork preserved work, never overwrite a changed base or repin assignments."
  def recover_working_copy(campaign, dm_id, id, attrs) do
    manage(campaign, dm_id, fn current ->
      original = fetch!(WorkingCopy, current.id, id)
      # The creation snapshot is retained even when another tab adds nodes or releases.
      # Recovery must not require the stale tab to include those later edits.
      validate_persistence_text!(attrs)

      unless is_map(attrs) and is_binary(attrs[:name]) and is_binary(attrs[:content_id]) and
               Authoring.safe_edit?(original.source_definition, attrs[:definition]),
             do: Repo.rollback(:unsupported_edit)

      recovered_name = attrs[:name] <> " (recovered)"
      validate_persistence_text!(Map.put(attrs, :name, recovered_name))

      Repo.insert!(%WorkingCopy{
        campaign_id: current.id,
        name: recovered_name,
        content_id: "recovered_" <> Ecto.UUID.generate(),
        definition: attrs[:definition],
        source_definition: attrs[:definition]
      })
    end)
  end

  defp new_content_id, do: "quest_" <> Ecto.UUID.generate()

  defp editable_work!(current, id, version) do
    draft = fetch!(WorkingCopy, current.id, id)
    if draft.version != version, do: Repo.rollback(:stale_working_copy)

    if draft.quest_id do
      latest =
        Repo.one(
          from r in Revision,
            where: r.quest_id == ^draft.quest_id,
            order_by: [desc: r.number],
            limit: 1
        )

      if latest.id != draft.base_revision_id, do: Repo.rollback(:stale_base_revision)
    end

    draft
  end

  defp validate_persistence_text!(attrs) do
    errors = Authoring.persistence_errors(attrs)
    if errors != [], do: Repo.rollback({:validation, errors})
  end

  defp update_work!(draft, attrs) do
    validate_persistence_text!(attrs)

    unless is_map(attrs) and is_binary(attrs[:name]) and is_binary(attrs[:content_id]) and
             Authoring.safe_edit?(draft.definition, attrs[:definition]),
           do: Repo.rollback(:unsupported_edit)

    if draft.quest_id != nil and draft.content_id != attrs[:content_id],
      do: Repo.rollback(:immutable_content_id)

    # Pre-generation drafts may retain blank or invalid identities. Repair only
    # unreleased work, within the same version-checked save/release transaction.
    attrs =
      if is_nil(draft.quest_id) and not Definition.id?(attrs[:content_id]),
        do: Map.put(attrs, :content_id, new_content_id()),
        else: attrs

    draft
    |> change(
      Map.take(attrs, [:name, :content_id, :definition])
      |> Map.put(:version, draft.version + 1)
    )
    |> Repo.update!()
  end

  @doc "Atomically imports versioned JSON. Exact latest definition/name repeats reuse revisions."
  def import_json(campaign, dm_id, json, opts \\ []) do
    manage(campaign, dm_id, fn current ->
      clocks = clock_map(current.id)
      bindings = Keyword.get(opts, :clock_refs, %{})

      quests =
        case AsyncWorlds.Quests.Import.decode(json, clocks, bindings) do
          {:ok, quests} -> quests
          {:error, errors} -> Repo.rollback(errors)
        end

      Enum.map(quests, fn entry ->
        quest = Repo.get_by(Quest, campaign_id: current.id, content_id: entry["content_id"])

        latest =
          quest &&
            Repo.one(
              from r in Revision,
                where: r.quest_id == ^quest.id,
                order_by: [desc: r.number],
                limit: 1
            )

        if latest && latest.definition == entry["definition"] && quest.name == entry["name"] do
          %{action: :unchanged, revision: latest}
        else
          action = if quest, do: :appended, else: :created

          quest =
            if quest do
              Repo.update!(change(quest, name: entry["name"]))
            else
              Repo.insert!(%Quest{
                campaign_id: current.id,
                content_id: entry["content_id"],
                name: entry["name"]
              })
            end

          %{action: action, revision: append!(current.id, quest.id, entry["definition"])}
        end
      end)
    end)
  end

  @doc "Freshly authorized clock creation for trusted operators and other shared callers."
  def create_clock(campaign, dm_id, attrs) do
    manage(campaign, dm_id, fn current ->
      name = if is_map(attrs), do: Map.get(attrs, :name) || Map.get(attrs, "name")

      unless Definition.text?(name) and byte_size(name) <= 200,
        do: Repo.rollback(:invalid_clock_name)

      case Clocks.create_clock(current.id, attrs, "dm:#{current.dm_user_id}") do
        {:ok, clock} -> clock
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  def create_quest(campaign, dm_id, attrs, definition) do
    manage(campaign, dm_id, fn current ->
      unless is_map(attrs) and not is_struct(attrs) and Definition.id?(attrs[:content_id]) and
               Definition.text?(attrs[:name]) and byte_size(attrs[:name]) <= 200,
             do: Repo.rollback(:invalid_quest)

      quest =
        %Quest{campaign_id: current.id}
        |> change(Map.take(attrs, [:content_id, :name]))
        |> unique_constraint([:campaign_id, :content_id])
        |> Repo.insert()
        |> persist()

      append!(current.id, quest.id, definition)
    end)
  end

  @doc "DM-only published quest availability; unlocks never interrupt an assignment."
  def list_unlocked(campaign, dm_id, character_id) do
    manage(campaign, dm_id, fn current ->
      fetch!(Character, current.id, character_id)

      Repo.all(
        from q in Quest,
          join: u in AsyncWorlds.Quests.Unlock,
          on: u.quest_id == q.id,
          where: u.campaign_id == ^current.id and u.character_id == ^character_id,
          order_by: q.id
      )
    end)
  end

  def append_revision(campaign, dm_id, quest_id, definition) do
    manage(campaign, dm_id, fn current ->
      quest = fetch!(Quest, current.id, quest_id)
      append!(current.id, quest.id, definition)
    end)
  end

  @doc "Shared authorized management of modeled on-fill trigger targets."
  def configure_clock_triggers(campaign, dm_id, clock_id, triggers) do
    manage(campaign, dm_id, fn current ->
      clock = fetch!(AsyncWorlds.Clocks.Clock, current.id, clock_id)

      case Clocks.edit_clock(
             current.id,
             clock.id,
             %{triggers: triggers},
             "dm:#{current.dm_user_id}"
           ) do
        {:ok, clock} -> clock
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  def get_revision(campaign, dm_id, revision_id),
    do: manage(campaign, dm_id, fn current -> fetch!(Revision, current.id, revision_id) end)

  def get_progression(campaign, dm_id, progression_id),
    do: manage(campaign, dm_id, fn current -> fetch!(Progression, current.id, progression_id) end)

  @doc "Audited assignment. Optional expected_progression prevents stale operational editors."
  def assign(campaign, dm_id, character_id, revision_id, opts \\ []) do
    manage(campaign, dm_id, fn current ->
      mutable!(current)
      character = fetch!(Character, current.id, character_id)
      expect!(active(current.id, character.id), opts)
      reason = reason!(opts, "Assign quest")
      invalidated = open_submission_count(current.id, character.id)
      assigned = assign!(current.id, character.id, revision_id)
      audit!(current, "assign", nil, assigned, reason, invalidated)
      assigned
    end)
  end

  def swap(campaign, dm_id, character_id, revision_id, opts \\ []) do
    manage(campaign, dm_id, fn current ->
      mutable!(current)
      character = fetch!(Character, current.id, character_id)
      previous = active(current.id, character.id)
      expect!(previous, opts)
      reason = reason!(opts, "Swap quest")
      invalidated = open_submission_count(current.id, character.id)
      Submissions.invalidate_open(current.id, character.id)
      if previous, do: Repo.update!(change(previous, status: :ended))
      assigned = assign!(current.id, character.id, revision_id)
      audit!(current, "swap", previous, assigned, reason, invalidated)
      assigned
    end)
  end

  def end_quest(campaign, dm_id, progression_id, opts \\ []) do
    manage(campaign, dm_id, fn current ->
      mutable!(current)
      progression = fetch!(Progression, current.id, progression_id)
      expect!(progression, opts)
      if progression.status != :active, do: Repo.rollback(:not_active)
      reason = reason!(opts, "End quest")
      invalidated = open_submission_count(current.id, progression.character_id)
      Submissions.invalidate_open(current.id, progression.character_id)
      ended = Repo.update!(change(progression, status: :ended))
      audit!(current, "end", progression, ended, reason, invalidated)
      ended
    end)
  end

  def move(campaign, dm_id, progression_id, node_id, opts \\ []) do
    manage(campaign, dm_id, fn current ->
      mutable!(current)
      progression = fetch!(Progression, current.id, progression_id)
      expect!(progression, opts)
      if progression.status != :active, do: Repo.rollback(:not_active)
      revision = fetch!(Revision, current.id, progression.revision_id)
      node = Rules.node(revision.definition, node_id) || Repo.rollback(:invalid_node)
      reason = reason!(opts, "Move quest node")

      if progression.node_id == node_id do
        progression
      else
        invalidated = open_submission_count(current.id, progression.character_id)
        Submissions.invalidate_open(current.id, progression.character_id)

        moved =
          Repo.update!(
            change(progression,
              node_id: node_id,
              status: status(node),
              position_version: progression.position_version + 1
            )
          )

        audit!(current, "move", progression, moved, reason, invalidated)
        moved
      end
    end)
  end

  @doc "Freshly authorized, consistent operational view; definitions/history never go to players."
  def management_state(campaign, dm_id, character_id \\ nil) do
    manage(campaign, dm_id, fn current ->
      characters =
        Repo.all(
          from c in Character,
            left_join: p in Progression,
            on: p.character_id == c.id and p.status == :active,
            left_join: r in Revision,
            on: r.id == p.revision_id,
            left_join: q in Quest,
            on: q.id == r.quest_id,
            where: c.campaign_id == ^current.id,
            order_by: c.id,
            select: %{
              id: c.id,
              name: c.name,
              discord_user_id: c.discord_user_id,
              progression: p,
              quest_name: q.name,
              revision_number: r.number
            }
        )

      revisions =
        Repo.all(
          from r in Revision,
            join: q in Quest,
            on: q.id == r.quest_id,
            where: r.campaign_id == ^current.id,
            order_by: [q.name, q.id, desc: r.number],
            select: %{id: r.id, quest_name: q.name, content_id: q.content_id, number: r.number}
        )

      selected =
        if character_id do
          character = fetch!(Character, current.id, character_id)
          row = Enum.find(characters, &(&1.id == character.id))
          revision = row.progression && fetch!(Revision, current.id, row.progression.revision_id)
          Map.put(row, :revision, revision)
        end

      audits = if selected, do: recent_interventions(current.id, selected.id), else: []

      %{
        characters: characters,
        revisions: revisions,
        selected: selected,
        audits: audits,
        locked: current.clock_mutations_locked
      }
    end)
  end

  def list_interventions(campaign, dm_id, character_id) do
    manage(campaign, dm_id, fn current ->
      character = fetch!(Character, current.id, character_id)
      recent_interventions(current.id, character.id)
    end)
  end

  @doc "Freshly authorized public-safe roster from pinned quest revisions, not latest library content."
  def public_activities(campaign, dm_id) do
    manage(campaign, dm_id, fn current ->
      characters =
        Repo.all(from c in Character, where: c.campaign_id == ^current.id, order_by: c.id)

      progressions =
        Repo.all(
          from p in Progression,
            where: p.campaign_id == ^current.id,
            distinct: p.character_id,
            order_by: [asc: p.character_id, desc: p.id]
        )

      revision_ids = Enum.map(progressions, & &1.revision_id)

      definitions =
        Repo.all(
          from r in Revision,
            where: r.campaign_id == ^current.id and r.id in ^revision_ids
        )
        |> Map.new(&{&1.id, &1.definition})

      positions = Map.new(progressions, &{&1.character_id, &1})

      Enum.map(characters, fn character ->
        activity =
          case positions[character.id] do
            nil ->
              AsyncWorlds.Quests.PublicActivity.project(nil, nil, nil)

            progression ->
              AsyncWorlds.Quests.PublicActivity.project(
                definitions[progression.revision_id],
                progression.node_id,
                progression.status
              )
          end

        Map.merge(activity, %{character_id: character.id, name: character.name})
      end)
    end)
  end

  @doc "DM-only immutable definition copies. Tick close uses Submissions.freeze/2 for full inputs."
  def freeze_definitions(campaign, dm_id) do
    manage(campaign, dm_id, fn current ->
      Repo.all(
        from r in Revision, where: r.campaign_id == ^current.id, order_by: [r.quest_id, r.number]
      )
      |> Enum.map(fn revision ->
        %{
          "revision_id" => revision.id,
          "quest_id" => revision.quest_id,
          "number" => revision.number,
          "definition" => revision.definition
        }
      end)
      |> Jason.encode!()
      |> Jason.decode!()
    end)
  end

  @doc "Read-only safe projection using verified player identity; no arbitrary character selector."
  def player_quest(guild_id, verified_user_id) do
    AsyncWorlds.PlayerAccess.run(guild_id, verified_user_id, fn current, character ->
      progression =
        active(current.id, character.id) || latest_completed(current.id, character.id) ||
          Repo.rollback(:no_quest)

      revision = fetch!(Revision, current.id, progression.revision_id)

      Rules.project(revision.definition, %{
        node_id: progression.node_id,
        status: progression.status,
        flags: character.flags,
        clocks: clock_map(current.id)
      })
    end)
  end

  defp append!(campaign_id, quest_id, definition) do
    unless Definition.valid?(definition, clock_map(campaign_id)),
      do: Repo.rollback(:invalid_definition)

    number =
      Repo.one(from r in Revision, where: r.quest_id == ^quest_id, select: max(r.number)) || 0

    revision =
      Repo.insert!(%Revision{
        campaign_id: campaign_id,
        quest_id: quest_id,
        number: number + 1,
        definition: definition
      })

    Repo.insert_all(
      "quest_revision_nodes",
      Enum.map(definition["nodes"], &%{revision_id: revision.id, node_id: &1["id"]})
    )

    revision
  end

  defp assign!(campaign_id, character_id, revision_id) do
    character = fetch!(Character, campaign_id, character_id)
    revision = fetch!(Revision, campaign_id, revision_id)
    if active(campaign_id, character.id), do: Repo.rollback(:active_quest)
    Submissions.invalidate_open(campaign_id, character.id)
    node = Rules.node(revision.definition, revision.definition["start_node"])

    %Progression{
      campaign_id: campaign_id,
      character_id: character.id,
      revision_id: revision.id,
      node_id: node["id"],
      status: status(node)
    }
    |> change()
    |> unique_constraint(:character_id, name: :one_active_quest_per_character)
    |> Repo.insert()
    |> persist()
  end

  defp recent_interventions(campaign_id, character_id) do
    Repo.all(
      from a in Intervention,
        where: a.campaign_id == ^campaign_id and a.character_id == ^character_id,
        order_by: [desc: a.id],
        limit: 10
    )
  end

  defp expect!(progression, opts) do
    case Keyword.fetch(opts, :expected_progression) do
      {:ok, expected} when expected != progression -> Repo.rollback(:stale_progression)
      _ -> :ok
    end
  end

  defp reason!(opts, default) do
    reason = Keyword.get(opts, :reason, default)

    unless Definition.text?(reason) and
             length(String.to_charlist(String.trim(reason))) in 1..2000,
           do: Repo.rollback(:invalid_reason)

    String.trim(reason)
  end

  defp open_submission_count(campaign_id, character_id) do
    Repo.aggregate(
      from(s in Submission,
        join: t in Tick,
        on: t.id == s.tick_id,
        where:
          s.campaign_id == ^campaign_id and s.character_id == ^character_id and t.status == :open
      ),
      :count
    )
  end

  defp audit!(campaign, operation, before, after_progression, reason, invalidated) do
    tick = AsyncWorlds.Ticks.active_tick(campaign.id)

    Repo.insert!(%Intervention{
      campaign_id: campaign.id,
      character_id: after_progression.character_id,
      tick_id: tick && tick.id,
      actor_id: campaign.dm_user_id,
      operation: operation,
      reason: reason,
      before: position(before),
      after: position(after_progression),
      invalidated_submissions: invalidated
    })
  end

  defp position(nil), do: nil

  defp position(progression) do
    progression
    |> Map.take([:id, :character_id, :revision_id, :node_id, :position_version, :status])
    |> Jason.encode!()
    |> Jason.decode!()
  end

  defp mutable!(campaign) do
    if campaign.clock_mutations_locked, do: Repo.rollback(:tick_locked)
  end

  defp status(%{"ending" => true}), do: :completed
  defp status(_), do: :active

  defp active(campaign_id, character_id),
    do:
      Repo.get_by(Progression,
        campaign_id: campaign_id,
        character_id: character_id,
        status: :active
      )

  defp latest_completed(campaign_id, character_id),
    do:
      Repo.one(
        from p in Progression,
          where:
            p.campaign_id == ^campaign_id and p.character_id == ^character_id and
              p.status == :completed,
          order_by: [desc: p.id],
          limit: 1
      )

  defp clock_map(campaign_id), do: Map.new(Clocks.list_clocks(campaign_id), &{&1.id, &1})

  defp manage(%Campaign{id: id}, dm_id, fun) when is_integer(id) and id > 0 do
    with {:ok, user_id} <- normalize(dm_id) do
      Repo.transaction(fn ->
        current = lock!(id)
        unless Campaigns.dm?(current, user_id), do: Repo.rollback(:unauthorized)
        fun.(current)
      end)
    end
  end

  defp manage(_, _, _), do: {:error, :invalid_campaign}

  defp lock!(id),
    do:
      Repo.one(from c in Campaign, where: c.id == ^id, lock: "FOR UPDATE") ||
        Repo.rollback(:not_found)

  defp fetch!(schema, campaign_id, raw_id) do
    with {:ok, id} when is_integer(id) and id > 0 and id <= 9_223_372_036_854_775_807 <-
           Ecto.Type.cast(:id, raw_id),
         record when not is_nil(record) <- Repo.get_by(schema, campaign_id: campaign_id, id: id) do
      record
    else
      _ -> Repo.rollback(:not_found)
    end
  end

  defp persist({:ok, record}), do: record
  defp persist({:error, reason}), do: Repo.rollback(reason)

  defp normalize(id) do
    case Snowflake.cast(id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :invalid_id}
    end
  end
end
