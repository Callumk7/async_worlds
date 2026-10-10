defmodule AsyncWorlds.Clocks do
  @moduledoc """
  Campaign-scoped clock management for shared web/Discord callers.

  All writes serialize on the campaign row. Tick closing must call
  `lock_mutations/1` in the same transaction as freezing inputs; publication
  must apply its approved state and call `unlock_mutations/1` in one transaction.
  Resolving/review rejects ALL management, including creation and racing edits.
  Callers authorize the DM before entering this domain boundary.
  """
  import Ecto.Query
  import Ecto.Changeset
  alias AsyncWorlds.Campaigns.Campaign
  alias AsyncWorlds.Clocks.{Audit, Clock, Rules}
  alias AsyncWorlds.Repo

  def list_clocks(campaign_id) do
    Repo.all(from c in Clock, where: c.campaign_id == ^campaign_id, order_by: c.id)
  end

  def list_audits(campaign_id) do
    Repo.all(from a in Audit, where: a.campaign_id == ^campaign_id, order_by: a.id)
  end

  def recent_audits(campaign_id, limit \\ 8) do
    Repo.all(
      from a in Audit, where: a.campaign_id == ^campaign_id, order_by: [desc: a.id], limit: ^limit
    )
  end

  def create_clock(campaign_id, attrs, source) do
    manage(campaign_id, source, fn ->
      changeset = Clock.changeset(%Clock{campaign_id: campaign_id}, attrs)
      validate_references!(changeset, campaign_id)
      clock = persist(Repo.insert(changeset))
      audit(nil, clock, "create", source)
      clock
    end)
  end

  def edit_clock(campaign_id, clock_id, attrs, source, expected_clock \\ nil) do
    manage(campaign_id, source, fn ->
      clock = fetch!(campaign_id, clock_id)
      if expected_clock && expected_clock != clock, do: Repo.rollback(:stale_clock)
      if clock.completed, do: Repo.rollback(:completed)
      changeset = Clock.changeset(clock, attrs)
      validate_references!(changeset, campaign_id)
      updated = persist(Repo.update(changeset))
      audit(clock, updated, "edit", source)
      updated
    end)
  end

  def adjust_clock(campaign_id, clock_id, delta, source) when is_integer(delta) do
    manage(campaign_id, source, fn ->
      clock = fetch!(campaign_id, clock_id)
      if clock.completed, do: Repo.rollback(:completed)
      updated = persist(Repo.update(change(clock, filled: Rules.adjust(clock, delta).filled)))
      audit(clock, updated, "adjust", source)
      updated
    end)
  end

  def adjust_clock(_, _, _, _), do: {:error, :invalid_delta}

  @doc "Reset clears fill/completion, preserves pause/configuration, and resets both racing members."
  def reset_clock(campaign_id, clock_id, source) do
    manage(campaign_id, source, fn ->
      clock = fetch!(campaign_id, clock_id)

      members =
        if clock.racing_group, do: race_members(campaign_id, clock.racing_group), else: [clock]

      updated =
        Enum.map(members, fn member ->
          reset = persist(Repo.update(change(member, filled: 0, completed: false)))
          audit(member, reset, "reset", source)
          reset
        end)

      Enum.find(updated, &(&1.id == clock_id))
    end)
  end

  def pair_clocks(campaign_id, first_id, second_id, source) do
    manage(campaign_id, source, fn ->
      if first_id == second_id, do: Repo.rollback(:self_link)
      members = [fetch!(campaign_id, first_id), fetch!(campaign_id, second_id)]
      if Enum.any?(members, & &1.racing_group), do: Repo.rollback(:already_paired)
      if Enum.any?(members, & &1.completed), do: Repo.rollback(:completed)
      group = Ecto.UUID.generate()

      Enum.map(members, fn clock ->
        updated = persist(Repo.update(change(clock, racing_group: group)))
        audit(clock, updated, "pair", source)
        updated
      end)
    end)
  end

  def unpair_clock(campaign_id, clock_id, source) do
    manage(campaign_id, source, fn ->
      clock = fetch!(campaign_id, clock_id)

      members =
        if clock.racing_group, do: race_members(campaign_id, clock.racing_group), else: [clock]

      Enum.map(members, fn member ->
        updated = persist(Repo.update(change(member, racing_group: nil)))
        audit(member, updated, "unpair", source)
        updated
      end)
    end)
  end

  @doc "Latches a filled clock and racing loser; returns world actions without delivering them."
  def complete_clock(campaign_id, clock_id, source) do
    manage(campaign_id, source, fn ->
      clock = fetch!(campaign_id, clock_id)

      loser =
        if clock.racing_group do
          Enum.find(race_members(campaign_id, clock.racing_group), &(&1.id != clock.id))
        end

      if clock.completed, do: Repo.rollback(:completed)
      if clock.filled != clock.segments, do: Repo.rollback(:not_filled)
      {winner, loser, actions} = Rules.complete(clock, loser)

      Enum.each(Enum.reject([winner, loser], &is_nil/1), fn member ->
        original = fetch!(campaign_id, member.id)
        updated = persist(Repo.update(change(original, completed: member.completed)))
        audit(original, updated, "complete", source)
      end)

      %{clock: winner, actions: actions}
    end)
  end

  def lock_mutations(campaign_id), do: set_lock(campaign_id, true)
  def unlock_mutations(campaign_id), do: set_lock(campaign_id, false)

  defp set_lock(campaign_id, value) do
    Repo.transaction(fn ->
      campaign = campaign!(campaign_id)

      if not value and frozen_tick?(campaign_id), do: Repo.rollback(:active_tick)
      persist(Repo.update(change(campaign, clock_mutations_locked: value)))
    end)
  end

  defp manage(campaign_id, source, fun) do
    if is_binary(source) and String.trim(source) != "" do
      Repo.transaction(fn ->
        campaign = campaign!(campaign_id)

        if campaign.clock_mutations_locked or frozen_tick?(campaign_id),
          do: Repo.rollback(:tick_locked)

        fun.()
      end)
    else
      {:error, :invalid_source}
    end
  end

  defp frozen_tick?(campaign_id) do
    Repo.exists?(
      from t in AsyncWorlds.Ticks.Tick,
        where: t.campaign_id == ^campaign_id and t.status in [:resolving, :in_review]
    )
  end

  defp campaign!(id) do
    Repo.one(from c in Campaign, where: c.id == ^id, lock: "FOR UPDATE") ||
      Repo.rollback(:not_found)
  end

  defp fetch!(campaign_id, id) do
    Repo.get_by(Clock, id: id, campaign_id: campaign_id) || Repo.rollback(:not_found)
  end

  defp race_members(campaign_id, group) do
    Repo.all(
      from c in Clock,
        where: c.campaign_id == ^campaign_id and c.racing_group == ^group,
        order_by: c.id
    )
  end

  defp validate_references!(changeset, campaign_id) do
    if changeset.valid? do
      Enum.each(get_field(changeset, :triggers), fn trigger ->
        if trigger.type == :start_clock do
          target = Repo.get_by(Clock, id: trigger.clock_id, campaign_id: campaign_id)

          if is_nil(target) or trigger.clock_id == changeset.data.id,
            do:
              Repo.rollback(
                add_error(changeset, :triggers, "must reference another clock in this campaign")
              )
        end
      end)
    end
  end

  defp persist({:ok, value}), do: value
  defp persist({:error, changeset}), do: Repo.rollback(changeset)

  defp audit(before, after_clock, operation, source) do
    Repo.insert!(%Audit{
      campaign_id: after_clock.campaign_id,
      clock_id: after_clock.id,
      source: source,
      operation: operation,
      before: snapshot(before),
      after: snapshot(after_clock)
    })
  end

  defp snapshot(nil), do: %{}

  defp snapshot(clock) do
    clock
    |> Map.take([
      :name,
      :segments,
      :filled,
      :visibility,
      :background_rate,
      :paused,
      :completed,
      :racing_group
    ])
    |> Map.put(:triggers, Enum.map(clock.triggers, &Map.take(&1, [:type, :text, :clock_id])))
  end
end
