defmodule AsyncWorlds.Ticks do
  @moduledoc """
  Shared manual tick lifecycle. Interfaces authorize the campaign DM first.

  Writers lock the campaign before the tick, matching clock management's lock
  order. Snapshots and drafts are DM-only; public readers use live clocks and
  `latest_published_tick/1`, never draft payloads. Close atomically queues durable
  resolution. Audited review operations and atomic world publication share this
  boundary. Interfaces authorize all DM-only reads and mutations.
  """
  import Ecto.Query
  import Ecto.Changeset
  alias AsyncWorlds.{Clocks, Repo}
  alias AsyncWorlds.Campaigns.Campaign
  alias AsyncWorlds.Ticks.{Draft, Output, Publication, ReviewEdit, Snapshot, Tick, WorldResolver}
  alias AsyncWorlds.Clocks.{Audit, Clock}
  alias AsyncWorlds.Deliveries

  def fetch_tick(campaign_id, tick_id) do
    case Repo.get_by(Tick, id: tick_id, campaign_id: campaign_id) do
      nil -> {:error, :not_found}
      tick -> {:ok, tick}
    end
  end

  def active_tick(campaign_id) do
    Repo.one(from t in Tick, where: t.campaign_id == ^campaign_id and t.status != :published)
  end

  def latest_published_tick(campaign_id) do
    Repo.one(
      from t in Tick,
        where: t.campaign_id == ^campaign_id and t.status == :published,
        order_by: [desc: t.number],
        limit: 1
    )
  end

  def fetch_snapshot(campaign_id, tick_id) do
    with {:ok, _tick} <- fetch_tick(campaign_id, tick_id) do
      case Repo.get_by(Snapshot, tick_id: tick_id) do
        nil -> {:error, :not_closed}
        snapshot -> {:ok, snapshot}
      end
    end
  end

  @doc "Trusted worker boundary: commit missing dice before pure resolution, serialized with lifecycle writes."
  def record_quest_rolls(campaign_id, tick_id, revision, roller \\ fn -> :rand.uniform(6) end) do
    transaction(campaign_id, tick_id, fn _campaign, tick ->
      if tick.status not in [:resolving, :in_review, :published],
        do: invalid_transition!(tick, :roll)

      snapshot = snapshot!(tick)
      if snapshot.revision != revision, do: Repo.rollback(:stale_input)
      unless WorldResolver.valid_snapshot?(snapshot), do: Repo.rollback(:invalid_snapshot)
      specs = AsyncWorlds.Ticks.QuestDice.specs(snapshot)
      existing = Map.new(rolls(snapshot), &{&1["identity"], &1})

      for spec <- specs do
        if existing[spec["identity"]] do
          existing[spec["identity"]]
        else
          if tick.status != :resolving, do: Repo.rollback(:invalid_rolls)
          value = roller.()
          unless is_integer(value) and value in 1..6, do: Repo.rollback(:invalid_rolls)

          Repo.insert!(%AsyncWorlds.Ticks.Roll{
            snapshot_id: snapshot.id,
            identity: spec["identity"],
            input: spec["input"],
            die_index: spec["die_index"],
            value: value
          })

          Map.put(spec, "value", value)
        end
      end
    end)
  end

  defp rolls(snapshot) do
    by_identity =
      Repo.all(from r in AsyncWorlds.Ticks.Roll, where: r.snapshot_id == ^snapshot.id)
      |> Map.new(fn r ->
        {r.identity,
         %{
           "identity" => r.identity,
           "input" => r.input,
           "die_index" => r.die_index,
           "value" => r.value
         }}
      end)

    AsyncWorlds.Ticks.QuestDice.specs(snapshot)
    |> Enum.flat_map(fn spec ->
      case by_identity[spec["identity"]] do
        nil -> []
        roll -> [roll]
      end
    end)
  end

  defp resolve_snapshot(snapshot, review),
    do: WorldResolver.resolve(snapshot, review, rolls(snapshot))

  @doc "Freshly authorized DM retrieval. Never expose a raw draft through player commands."
  def fetch_draft(guild_id, actor_id, tick_id) do
    with {:ok, campaign} <- AsyncWorlds.Campaigns.authorize_dm(guild_id, actor_id) do
      fetch_draft(campaign.id, tick_id)
    end
  end

  def fetch_draft(campaign_id, tick_id) do
    with {:ok, tick} <- fetch_tick(campaign_id, tick_id) do
      case current_draft(tick) do
        nil -> {:error, :no_draft}
        draft -> {:ok, draft}
      end
    end
  end

  @doc "DM-only resolution diagnostics, scoped to the owning campaign and tick."
  def resolution_jobs(campaign_id, tick_id) do
    with {:ok, _} <- fetch_tick(campaign_id, tick_id) do
      {:ok,
       Repo.all(
         from j in Oban.Job,
           where:
             j.worker == "AsyncWorlds.Workers.ResolveTick" and
               fragment("?->>'tick_id' = ?", j.args, ^to_string(tick_id)) and
               fragment("?->>'campaign_id' = ?", j.args, ^to_string(campaign_id)),
           order_by: j.id
       )}
    end
  end

  @doc "Opens the next numbered tick. Duplicate opens return :active_tick, not another turn."
  def open_tick(campaign_id) do
    Repo.transaction(fn ->
      campaign = lock_campaign!(campaign_id)
      if active_tick(campaign_id), do: Repo.rollback(:active_tick)
      if campaign.clock_mutations_locked, do: Repo.rollback(:tick_locked)

      tick =
        %Tick{
          campaign_id: campaign_id,
          number: campaign.current_tick_number + 1,
          opened_at: now()
        }
        |> change()
        |> unique_constraint(:campaign_id, name: :one_active_tick_per_campaign)
        |> unique_constraint([:campaign_id, :number])
        |> Repo.insert()
        |> persist!()

      # Shared by web and Discord: commit the announcement with the open, never
      # perform network I/O here or enqueue from an interface after committing.
      Deliveries.enqueue(campaign_id, tick.id, %{
        key: "tick:#{tick.id}:opened",
        kind: :public,
        recipient_id: campaign.public_channel_id,
        content: "Tick #{tick.number} is now open."
      })
      |> persist!()

      tick
    end)
  end

  @doc "Atomically freezes world/quest inputs and locks management. Retries return the original snapshot."
  def close_tick(campaign_id, tick_id) do
    transaction(campaign_id, tick_id, fn campaign, tick ->
      case tick.status do
        :open ->
          {:ok, _} = Clocks.lock_mutations(campaign_id)

          snapshot =
            Repo.insert!(%Snapshot{
              tick_id: tick.id,
              schema_version: 2,
              revision: Ecto.UUID.generate(),
              data: freeze(campaign, tick)
            })

          closed = update!(tick, status: :resolving, closed_at: now())

          %{campaign_id: campaign_id, tick_id: tick.id, input_revision: snapshot.revision}
          |> AsyncWorlds.Workers.ResolveTick.new()
          |> Oban.insert()
          |> persist!()

          %{tick: closed, snapshot: snapshot}

        status when status in [:resolving, :in_review] ->
          %{tick: tick, snapshot: snapshot!(tick)}

        _ ->
          invalid_transition!(tick, :close)
      end
    end)
  end

  @doc """
  Stores a resolution/review draft and moves resolving to in_review.

  Input revision must match the frozen snapshot. First resolution expects nil
  draft ID; review edits require the current draft ID (optimistic concurrency).
  Each accepted write appends an immutable revision; stale workers/edits fail.
  Payload is JSON data, whose game semantics belong to the resolver (ENG-4).
  """
  def put_draft(campaign_id, tick_id, input_revision, payload, expected_draft_id \\ nil) do
    with {:ok, payload} <- json_payload(payload) do
      transaction(campaign_id, tick_id, fn _campaign, tick ->
        if tick.status not in [:resolving, :in_review], do: invalid_transition!(tick, :put_draft)
        snapshot = snapshot!(tick)
        if snapshot.revision != input_revision, do: Repo.rollback(:stale_input)
        current = current_draft(tick)
        current_id = if current, do: current.id
        if current_id != expected_draft_id, do: Repo.rollback(:stale_draft)

        draft =
          Repo.insert!(%Draft{
            tick_id: tick.id,
            input_revision: input_revision,
            revision: tick.draft_revision + 1,
            payload: payload
          })

        reviewed =
          update!(tick,
            status: :in_review,
            draft_revision: draft.revision,
            reviewed_at: tick.reviewed_at || now()
          )

        %{tick: reviewed, draft: draft}
      end)
    end
  end

  @doc """
  Publishes only the selected current draft. Duplicate publication is rejected
  before invoking the callback. `apply` receives %{tick, snapshot, draft} and must
  return {:ok, value} or {:error, reason}; its DB writes, tick transition, campaign
  number and management unlock commit together. It must not perform network I/O.
  Approved state/audits/outbox writes belong inside this callback (ENG-8/ENG-7).
  """
  # Trusted transaction primitive retained for future engine extensions. Interfaces
  # must use publish_tick/3, not supply their own state/publication implementation.
  def publish_tick(campaign_id, tick_id, expected_draft_id, apply) when is_function(apply, 1) do
    transaction(campaign_id, tick_id, fn campaign, tick ->
      if tick.status == :published, do: Repo.rollback(:already_published)
      if tick.status != :in_review, do: invalid_transition!(tick, :publish)
      draft = current_draft(tick)
      if is_nil(draft) or draft.id != expected_draft_id, do: Repo.rollback(:stale_draft)
      snapshot = snapshot!(tick)
      if draft.input_revision != snapshot.revision, do: Repo.rollback(:stale_input)

      case apply.(%{tick: tick, snapshot: snapshot, draft: draft}) do
        {:ok, _value} -> :ok
        {:error, reason} -> Repo.rollback(reason)
        _ -> Repo.rollback(:invalid_publication_result)
      end

      published = update!(tick, status: :published, published_at: now())
      update!(campaign, current_tick_number: tick.number)
      {:ok, _} = Clocks.unlock_mutations(campaign_id)
      published
    end)
  end

  @doc "Audited DM edit: replace a clock's tick delta or world-news narration; nil clears an override."
  def edit_draft(
        campaign_id,
        tick_id,
        expected_draft_id,
        operation,
        actor_id,
        reason,
        roller \\ fn -> :rand.uniform(6) end
      ) do
    with {:ok, operation} <- json_payload(operation) do
      transaction(campaign_id, tick_id, fn campaign, tick ->
        if actor_id != campaign.dm_user_id, do: Repo.rollback(:unauthorized)

        unless is_binary(reason) and String.valid?(reason) and not String.contains?(reason, <<0>>) and
                 String.trim(reason) != "" and String.length(reason) <= 2000,
               do: Repo.rollback(:invalid_reason)

        if tick.status != :in_review, do: invalid_transition!(tick, :edit_draft)
        draft = current_draft(tick)
        if draft.id != expected_draft_id, do: Repo.rollback(:stale_draft)
        snapshot = snapshot!(tick)
        review = review_state(tick)
        verify_draft!(draft, snapshot, review)
        validate_review_target!(operation, snapshot)
        operation = prepare_quest_operation!(operation, snapshot, review, roller)
        review = apply_review_operation(review, operation)

        payload =
          case resolve_snapshot(snapshot, review) do
            {:ok, payload} -> payload
            _ -> Repo.rollback(:invalid_edit)
          end

        {:ok, result} = put_draft(campaign_id, tick_id, snapshot.revision, payload, draft.id)

        edit =
          Repo.insert!(%ReviewEdit{
            tick_id: tick.id,
            previous_draft_id: draft.id,
            draft_id: result.draft.id,
            actor_id: actor_id,
            reason: reason,
            operation: operation
          })

        Map.put(result, :edit, edit)
      end)
    end
  end

  def list_review_edits(campaign_id, tick_id) do
    with {:ok, _} <- fetch_tick(campaign_id, tick_id) do
      {:ok, Repo.all(from e in ReviewEdit, where: e.tick_id == ^tick_id, order_by: e.id)}
    end
  end

  def fetch_publication(campaign_id, tick_id) do
    with {:ok, _} <- fetch_tick(campaign_id, tick_id) do
      case Repo.get_by(Publication, tick_id: tick_id) do
        nil -> {:error, :not_published}
        publication -> {:ok, publication}
      end
    end
  end

  @doc "DM-only preview of exact outgoing content for a selected current revision."
  def preview_draft(campaign_id, tick_id, expected_draft_id) do
    transaction(campaign_id, tick_id, fn _campaign, tick ->
      if tick.status != :in_review, do: invalid_transition!(tick, :preview)
      draft = current_draft(tick)
      if draft.id != expected_draft_id, do: Repo.rollback(:stale_draft)
      snapshot = snapshot!(tick)
      verify_draft!(draft, snapshot, review_state(tick))
      Output.render(draft.payload, snapshot.data["campaign"])
    end)
  end

  @doc "Apply the selected audited world draft, immutable history, and outbox in one transaction."
  def publish_tick(campaign_id, tick_id, expected_draft_id) do
    publish_tick(campaign_id, tick_id, expected_draft_id, fn %{
                                                               tick: tick,
                                                               snapshot: snapshot,
                                                               draft: draft
                                                             } ->
      verify_draft!(draft, snapshot, review_state(tick))
      campaign = Repo.get!(Campaign, campaign_id)

      if not campaign.clock_mutations_locked or campaign.current_tick_number != tick.number - 1,
        do: Repo.rollback(:stale_live_state)

      live = freeze(campaign, tick)
      # v1 predates character inputs. New immutable revisions may be authored
      # after close; they cannot affect the pinned frozen turn.
      live =
        if snapshot.schema_version == 1,
          do: Map.drop(live, ["quest_inputs", "quest_unlocks"]),
          else: live

      if comparable(live) != comparable(snapshot.data), do: Repo.rollback(:stale_live_state)

      Enum.each(draft.payload["effects"], fn effect ->
        before = effect["before"]
        after_clock = effect["after"]
        clock = Repo.get_by!(Clock, campaign_id: campaign_id, id: effect["clock_id"])

        update!(clock,
          filled: after_clock["filled"],
          paused: after_clock["paused"],
          completed: after_clock["completed"]
        )

        Repo.insert!(%Audit{
          campaign_id: campaign_id,
          clock_id: clock.id,
          operation: "publish",
          source: effect["source"],
          before: before,
          after: after_clock
        })
      end)

      apply_quest_state!(campaign_id, draft.payload)
      outputs = Output.render(draft.payload, snapshot.data["campaign"])

      Repo.insert!(%Publication{
        tick_id: tick.id,
        draft_id: draft.id,
        payload: draft.payload,
        outputs: outputs
      })

      for {audience, messages} <- outputs, {message, index} <- Enum.with_index(messages) do
        attrs =
          Map.put(
            message,
            "key",
            "tick:#{tick.id}:#{audience}:#{message["recipient_id"]}:#{index}"
          )

        case Deliveries.enqueue(campaign_id, tick.id, attrs) do
          {:ok, _} -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end
      end

      {:ok, :applied}
    end)
  end

  defp verify_draft!(draft, snapshot, review) do
    if draft.input_revision != snapshot.revision, do: Repo.rollback(:stale_input)

    case resolve_snapshot(snapshot, review) do
      {:ok, payload} when payload == draft.payload -> :ok
      _ -> Repo.rollback(:invalid_draft)
    end
  end

  defp review_state(tick) do
    snapshot = snapshot!(tick)
    edits = Repo.all(from e in ReviewEdit, where: e.tick_id == ^tick.id, order_by: e.id)
    initial = Repo.get_by!(Draft, tick_id: tick.id, revision: 1)
    verify_draft!(initial, snapshot, %{})

    {review, last_id} =
      Enum.reduce(edits, {%{}, initial.id}, fn edit, {review, previous} ->
        if edit.previous_draft_id != previous, do: Repo.rollback(:invalid_draft)
        op = edit.operation

        case op do
          %{"type" => "reroll", "identity" => id, "old_value" => old, "new_value" => value}
          when map_size(op) == 4 and is_integer(value) and value in 1..6 ->
            die =
              rolls(snapshot)
              |> AsyncWorlds.Ticks.QuestReview.dice(review)
              |> Enum.find(&(&1["identity"] == id))

            if is_nil(die) or die["value"] != old, do: Repo.rollback(:invalid_draft)

          %{"type" => "reroll"} ->
            Repo.rollback(:invalid_draft)

          %{"type" => type} when type in ["outcome", "player_narration"] ->
            case AsyncWorlds.Ticks.QuestReview.validate(snapshot, Map.delete(op, "key")) do
              {:ok, ^op} -> :ok
              _ -> Repo.rollback(:invalid_draft)
            end

          _ ->
            validate_review_target!(op, snapshot)
        end

        review = apply_review_operation(review, op)
        previous_draft = Repo.get!(Draft, previous)
        next_draft = Repo.get!(Draft, edit.draft_id)

        if next_draft.tick_id != tick.id or next_draft.revision != previous_draft.revision + 1,
          do: Repo.rollback(:invalid_draft)

        verify_draft!(next_draft, snapshot, review)
        {review, edit.draft_id}
      end)

    if last_id != current_draft(tick).id, do: Repo.rollback(:invalid_draft)
    review
  end

  defp apply_review_operation(
         review,
         %{"type" => "clock_delta", "clock_id" => id, "delta" => delta} = operation
       )
       when is_integer(id) and (is_integer(delta) or is_nil(delta)) and map_size(operation) == 3 do
    deltas = Map.get(review, "clock_deltas", %{})

    deltas =
      if is_nil(delta),
        do: Map.delete(deltas, to_string(id)),
        else: Map.put(deltas, to_string(id), delta)

    if map_size(deltas) == 0,
      do: Map.delete(review, "clock_deltas"),
      else: Map.put(review, "clock_deltas", deltas)
  end

  defp apply_review_operation(review, %{"type" => "world_news", "text" => news} = operation)
       when (is_list(news) or is_nil(news)) and map_size(operation) == 2 do
    if is_nil(news),
      do: Map.delete(review, "world_news"),
      else: Map.put(review, "world_news", news)
  end

  defp apply_review_operation(review, %{"type" => type} = operation)
       when type in ["reroll", "outcome", "player_narration"],
       do: AsyncWorlds.Ticks.QuestReview.apply_operation(review, operation)

  defp apply_review_operation(_, _), do: Repo.rollback(:invalid_edit)

  defp prepare_quest_operation!(
         %{"type" => "reroll", "identity" => id, "old_value" => old} = op,
         snapshot,
         review,
         roller
       )
       when map_size(op) == 3 do
    die =
      rolls(snapshot)
      |> AsyncWorlds.Ticks.QuestReview.dice(review)
      |> Enum.find(&(&1["identity"] == id))

    if is_nil(die) or die["value"] != old, do: Repo.rollback(:stale_identity)
    value = roller.()
    unless is_integer(value) and value in 1..6, do: Repo.rollback(:invalid_rolls)
    Map.put(op, "new_value", value)
  end

  defp prepare_quest_operation!(%{"type" => type} = op, snapshot, _review, _roller)
       when type in ["outcome", "player_narration"] do
    case AsyncWorlds.Ticks.QuestReview.validate(snapshot, op) do
      {:ok, op} -> op
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp prepare_quest_operation!(%{"type" => "reroll"}, _, _, _), do: Repo.rollback(:invalid_edit)
  defp prepare_quest_operation!(operation, _, _, _), do: operation

  defp apply_quest_state!(campaign_id, payload) do
    for c <- payload["characters"] || [] do
      character =
        Repo.get_by!(AsyncWorlds.Characters.Character, id: c["id"], campaign_id: campaign_id)

      update!(character, flags: c["flags"])
    end

    for p <- payload["progressions"] || [] do
      progression =
        Repo.get_by!(AsyncWorlds.Quests.Progression, id: p["id"], campaign_id: campaign_id)

      update!(progression,
        node_id: p["node_id"],
        status: String.to_existing_atom(p["status"]),
        position_version: p["position_version"]
      )
    end

    for unlock <- payload["unlocked_quests"] || [], quest_id <- unlock["quest_ids"] do
      Repo.insert!(
        %AsyncWorlds.Quests.Unlock{
          campaign_id: campaign_id,
          character_id: unlock["character_id"],
          quest_id: quest_id
        },
        on_conflict: :nothing,
        conflict_target: [:character_id, :quest_id]
      )
    end
  end

  defp validate_review_target!(%{"type" => "clock_delta", "clock_id" => id}, snapshot) do
    unless Enum.any?(snapshot.data["clocks"], &(&1["id"] == id and not &1["completed"])),
      do: Repo.rollback(:invalid_edit)
  end

  defp validate_review_target!(_, _), do: :ok

  defp transaction(campaign_id, tick_id, fun) do
    Repo.transaction(fn ->
      campaign = lock_campaign!(campaign_id)

      tick =
        Repo.one(
          from t in Tick,
            where: t.id == ^tick_id and t.campaign_id == ^campaign_id,
            lock: "FOR UPDATE"
        ) || Repo.rollback(:not_found)

      fun.(campaign, tick)
    end)
  end

  defp lock_campaign!(id) do
    Repo.one(from c in Campaign, where: c.id == ^id, lock: "FOR UPDATE") ||
      Repo.rollback(:not_found)
  end

  defp current_draft(tick),
    do: Repo.get_by(Draft, tick_id: tick.id, revision: tick.draft_revision)

  defp snapshot!(tick), do: Repo.get_by!(Snapshot, tick_id: tick.id)
  defp update!(record, attrs), do: record |> change(attrs) |> Repo.update!()
  defp persist!({:ok, record}), do: record
  defp persist!({:error, changeset}), do: Repo.rollback(changeset)

  defp invalid_transition!(tick, operation),
    do: Repo.rollback({:invalid_transition, tick.status, operation})

  defp now, do: DateTime.utc_now()

  defp json_payload(payload) when is_map(payload) and not is_struct(payload) do
    with {:ok, json} <- Jason.encode(payload), {:ok, decoded} <- Jason.decode(json) do
      {:ok, decoded}
    else
      _ -> {:error, :invalid_payload}
    end
  end

  defp json_payload(_), do: {:error, :invalid_payload}

  defp comparable(data) do
    if data["quest_inputs"] do
      data
      |> Map.put_new("quest_unlocks", [])
      |> update_in(["quest_inputs"], &Map.drop(&1, ["quests", "revisions"]))
    else
      data
    end
  end

  defp freeze(campaign, tick) do
    clocks = Clocks.list_clocks(campaign.id)

    %{
      "campaign" =>
        Map.take(campaign, [
          :id,
          :discord_guild_id,
          :dm_user_id,
          :public_channel_id,
          :current_tick_number
        ]),
      "tick_number" => tick.number,
      "quest_inputs" => AsyncWorlds.Quests.Submissions.freeze(campaign.id, tick.id),
      "quest_unlocks" =>
        Repo.all(
          from u in AsyncWorlds.Quests.Unlock,
            where: u.campaign_id == ^campaign.id,
            order_by: [u.character_id, u.quest_id],
            select: %{character_id: u.character_id, quest_id: u.quest_id}
        ),
      "ordering" => %{
        "clocks" => Enum.map(clocks, & &1.id),
        "race_tie_break" => "ascending_clock_id",
        "phases" => [
          "quest_choices",
          "resource_assignments",
          "background_rates",
          "clock_triggers",
          "quest_conditions"
        ]
      },
      "clocks" =>
        Enum.map(clocks, fn clock ->
          clock
          |> Map.take([
            :id,
            :campaign_id,
            :name,
            :segments,
            :filled,
            :visibility,
            :background_rate,
            :paused,
            :completed,
            :racing_group
          ])
          |> Map.put(
            :triggers,
            Enum.map(clock.triggers, &AsyncWorlds.Clocks.Trigger.snapshot/1)
          )
        end)
    }
    |> Jason.encode!()
    |> Jason.decode!()
  end
end
