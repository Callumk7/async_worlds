defmodule AsyncWorlds.Ticks do
  @moduledoc """
  Shared manual tick lifecycle. Interfaces authorize the campaign DM first.

  Writers lock the campaign before the tick, matching clock management's lock
  order. Snapshots and drafts are DM-only; public readers use live clocks and
  `latest_published_tick/1`, never draft payloads. Close atomically queues durable
  resolution; downstream writers supply a transactional publication callback.
  """
  import Ecto.Query
  import Ecto.Changeset
  alias AsyncWorlds.{Clocks, Repo}
  alias AsyncWorlds.Campaigns.Campaign
  alias AsyncWorlds.Ticks.{Draft, Snapshot, Tick}

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

      %Tick{campaign_id: campaign_id, number: campaign.current_tick_number + 1, opened_at: now()}
      |> change()
      |> unique_constraint(:campaign_id, name: :one_active_tick_per_campaign)
      |> unique_constraint([:campaign_id, :number])
      |> Repo.insert()
      |> persist!()
    end)
  end

  @doc "Atomically freezes world inputs and locks management. Retries return the original snapshot."
  def close_tick(campaign_id, tick_id) do
    transaction(campaign_id, tick_id, fn campaign, tick ->
      case tick.status do
        :open ->
          {:ok, _} = Clocks.lock_mutations(campaign_id)

          snapshot =
            Repo.insert!(%Snapshot{
              tick_id: tick.id,
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
            Enum.map(clock.triggers, &Map.take(&1, [:type, :text, :clock_id]))
          )
        end)
    }
    |> Jason.encode!()
    |> Jason.decode!()
  end
end
