defmodule AsyncWorlds.Quests.Submissions do
  @moduledoc "Authorized editable submissions and frozen quest inputs. See docs/quest-submissions.md."
  import Ecto.Query
  import Ecto.Changeset
  alias AsyncWorlds.{Campaigns, Clocks, Repo, Ticks}
  alias AsyncWorlds.Campaigns.Campaign
  alias AsyncWorlds.Characters.Character
  alias AsyncWorlds.Discord.Snowflake
  alias AsyncWorlds.Quests.{Progression, Quest, Revision, Rules, Submission}
  alias AsyncWorlds.Ticks.Tick

  @identity_keys [:tick_id, :progression_id, :revision_id, :node_id, :position_version]

  def submit(guild_id, verified_user_id, identity, choice_id) do
    player(guild_id, verified_user_id, fn campaign, character ->
      {tick, progression, revision} = validate_identity!(campaign, character, identity)

      unless eligible?(campaign.id, character, progression, revision, choice_id),
        do: Repo.rollback(:unavailable_choice)

      attrs =
        Map.merge(identity, %{
          campaign_id: campaign.id,
          character_id: character.id,
          choice_id: choice_id
        })

      existing = submission(tick.id, character.id) || %Submission{}
      existing |> change(attrs) |> Repo.insert_or_update!()
      %{identity: identity, choice_id: choice_id}
    end)
  end

  def clear(guild_id, verified_user_id, identity) do
    player(guild_id, verified_user_id, fn campaign, character ->
      {tick, progression, revision} = validate_identity!(campaign, character, identity)

      if existing = submission(tick.id, character.id) do
        unless valid_submission?(existing, campaign.id, character, progression, revision),
          do: Repo.rollback(:unavailable_choice)

        Repo.delete!(existing)
      end

      %{identity: identity, choice_id: nil}
    end)
  end

  def player_state(guild_id, verified_user_id) do
    player(guild_id, verified_user_id, fn campaign, character ->
      tick = Ticks.active_tick(campaign.id) || Repo.rollback(:no_tick)
      progression = active(campaign.id, character.id) || Repo.rollback(:no_quest)
      project_state(campaign, character, tick, progression)
    end)
  end

  @doc false
  # Trusted outbox helper: caller holds the campaign lock. No nested rollback on
  # unassigned/removed owners; those are simply inapplicable notifications.
  def notification_state(campaign, user_id) do
    with %Character{} = character <-
           Repo.get_by(Character, campaign_id: campaign.id, discord_user_id: user_id),
         %Tick{} = tick <- Ticks.active_tick(campaign.id),
         %Progression{} = progression <- active(campaign.id, character.id) do
      {:ok, project_state(campaign, character, tick, progression)}
    else
      _ -> {:error, :inapplicable}
    end
  end

  defp project_state(campaign, character, tick, progression) do
    revision = Repo.get!(Revision, progression.revision_id)
    existing = submission(tick.id, character.id)
    valid = existing && valid_submission?(existing, campaign.id, character, progression, revision)

    %{
      identity: identity(tick.id, progression),
      open: tick.status == :open,
      choice_id: if(valid, do: existing.choice_id),
      quest:
        Rules.project(revision.definition, %{
          node_id: progression.node_id,
          status: progression.status,
          flags: character.flags,
          clocks: clocks(campaign.id)
        })
    }
  end

  def readiness(campaign, dm_id, tick_id) do
    dm(campaign, dm_id, tick_id, fn current, tick ->
      if tick.status == :open do
        inputs = freeze(current.id, tick.id)
        counts(inputs)
      else
        {:ok, snapshot} = Ticks.fetch_snapshot(current.id, tick.id)
        counts(snapshot.data["quest_inputs"] || %{"progressions" => [], "submissions" => []})
      end
    end)
  end

  def list_submissions(campaign, dm_id, tick_id) do
    dm(campaign, dm_id, tick_id, fn current, tick ->
      if tick.status == :open do
        freeze(current.id, tick.id)["submissions"]
      else
        {:ok, snapshot} = Ticks.fetch_snapshot(current.id, tick.id)
        get_in(snapshot.data, ["quest_inputs", "submissions"]) || []
      end
    end)
  end

  defp counts(inputs) do
    active = length(inputs["progressions"])
    submitted = length(inputs["submissions"])
    %{active: active, submitted: submitted, missing: active - submitted}
  end

  @doc false
  # Trusted transaction helper: caller already owns the campaign lock.
  def invalidate_open(campaign_id, character_id) do
    open_ticks =
      from t in Tick, where: t.campaign_id == ^campaign_id and t.status == :open, select: t.id

    Repo.delete_all(
      from s in Submission,
        where:
          s.campaign_id == ^campaign_id and s.character_id == ^character_id and
            s.tick_id in subquery(open_ticks)
    )

    :ok
  end

  @doc false
  # Trusted DM-only snapshot builder; caller owns campaign lock, no public endpoint.
  def freeze(campaign_id, tick_id) do
    characters =
      Repo.all(from c in Character, where: c.campaign_id == ^campaign_id, order_by: c.id)

    progressions =
      Repo.all(
        from p in Progression,
          where: p.campaign_id == ^campaign_id and p.status == :active,
          order_by: p.id
      )

    revisions = Repo.all(from r in Revision, where: r.campaign_id == ^campaign_id, order_by: r.id)
    quests = Repo.all(from q in Quest, where: q.campaign_id == ^campaign_id, order_by: q.id)

    submitted =
      Repo.all(
        from s in Submission,
          where: s.campaign_id == ^campaign_id and s.tick_id == ^tick_id,
          order_by: s.character_id
      )

    clock_map = clocks(campaign_id)

    {valid, invalid} =
      Enum.split_with(submitted, fn s ->
        character = Enum.find(characters, &(&1.id == s.character_id))
        progression = Enum.find(progressions, &(&1.character_id == s.character_id))
        revision = progression && Enum.find(revisions, &(&1.id == progression.revision_id))

        character && progression && revision && matches?(s, progression) &&
          eligible_with?(character, progression, revision, s.choice_id, clock_map)
      end)

    %{
      "characters" => Enum.map(characters, &Map.take(&1, [:id, :name, :discord_user_id, :flags])),
      "progressions" =>
        Enum.map(
          progressions,
          &Map.take(&1, [:id, :character_id, :revision_id, :node_id, :position_version, :status])
        ),
      "quests" => Enum.map(quests, &Map.take(&1, [:id, :content_id, :name])),
      "revisions" => Enum.map(revisions, &Map.take(&1, [:id, :quest_id, :number, :definition])),
      "submissions" =>
        Enum.map(
          valid,
          &Map.take(&1, [
            :character_id,
            :progression_id,
            :revision_id,
            :node_id,
            :position_version,
            :choice_id
          ])
        ),
      "invalidations" =>
        Enum.map(invalid, &%{character_id: &1.character_id, reason: "stale_or_ineligible"})
    }
    |> Jason.encode!()
    |> Jason.decode!()
  end

  defp validate_identity!(campaign, character, identity) do
    unless valid_identity?(identity), do: Repo.rollback(:stale_identity)

    tick =
      Repo.one(
        from t in Tick,
          where: t.id == ^identity.tick_id and t.campaign_id == ^campaign.id,
          lock: "FOR UPDATE"
      ) || Repo.rollback(:stale_identity)

    latest_tick_id =
      Repo.one(
        from t in Tick,
          where: t.campaign_id == ^campaign.id,
          order_by: [desc: t.number],
          limit: 1,
          select: t.id
      )

    if tick.id != latest_tick_id, do: Repo.rollback(:stale_identity)
    if tick.status != :open, do: Repo.rollback(:tick_closed)
    progression = active(campaign.id, character.id) || Repo.rollback(:stale_identity)
    unless identity == identity(tick.id, progression), do: Repo.rollback(:stale_identity)
    {tick, progression, Repo.get!(Revision, progression.revision_id)}
  end

  defp valid_identity?(identity) when is_map(identity) and not is_struct(identity) do
    Enum.sort(Map.keys(identity)) == Enum.sort(@identity_keys) and
      Enum.all?([:tick_id, :progression_id, :revision_id, :position_version], fn key ->
        value = identity[key]
        is_integer(value) and value > 0 and value <= 9_223_372_036_854_775_807
      end) and is_binary(identity[:node_id])
  end

  defp valid_identity?(_), do: false

  defp identity(tick_id, progression),
    do: %{
      tick_id: tick_id,
      progression_id: progression.id,
      revision_id: progression.revision_id,
      node_id: progression.node_id,
      position_version: progression.position_version
    }

  defp matches?(s, p),
    do:
      s.progression_id == p.id and s.revision_id == p.revision_id and s.node_id == p.node_id and
        s.position_version == p.position_version

  defp valid_submission?(s, campaign_id, c, p, r),
    do: matches?(s, p) and eligible?(campaign_id, c, p, r, s.choice_id)

  defp eligible?(campaign_id, c, p, r, choice_id),
    do: eligible_with?(c, p, r, choice_id, clocks(campaign_id))

  defp eligible_with?(c, p, r, choice_id, clocks) do
    node = Rules.node(r.definition, p.node_id)
    choice = node && Enum.find(node["choices"], &(&1["id"] == choice_id))
    not is_nil(choice) and Rules.eligible?(choice, c.flags, clocks)
  end

  defp clocks(id), do: Map.new(Clocks.list_clocks(id), &{&1.id, &1})

  defp active(campaign_id, character_id),
    do:
      Repo.get_by(Progression,
        campaign_id: campaign_id,
        character_id: character_id,
        status: :active
      )

  defp submission(tick_id, character_id),
    do: Repo.get_by(Submission, tick_id: tick_id, character_id: character_id)

  defp player(guild_id, verified_user_id, fun) do
    with {:ok, user_id} <- normalize(verified_user_id),
         {:ok, expected} <- Campaigns.fetch_campaign_by_guild(guild_id) do
      Repo.transaction(fn ->
        campaign = lock!(expected.id)
        if campaign.discord_guild_id != expected.discord_guild_id, do: Repo.rollback(:not_found)

        character =
          Repo.get_by(Character, campaign_id: campaign.id, discord_user_id: user_id) ||
            Repo.rollback(:not_found)

        fun.(campaign, character)
      end)
    end
  end

  defp dm(%Campaign{id: id}, dm_id, tick_id, fun) do
    with {:ok, user_id} <- normalize(dm_id), {:ok, tick_id} <- cast_id(tick_id) do
      Repo.transaction(fn ->
        campaign = lock!(id)
        unless Campaigns.dm?(campaign, user_id), do: Repo.rollback(:unauthorized)
        tick = Repo.get_by(Tick, campaign_id: id, id: tick_id) || Repo.rollback(:not_found)
        fun.(campaign, tick)
      end)
    end
  end

  defp dm(_, _, _, _), do: {:error, :invalid_campaign}

  defp cast_id(id) when is_integer(id) and id > 0 and id <= 9_223_372_036_854_775_807,
    do: {:ok, id}

  defp cast_id(_), do: {:error, :not_found}

  defp lock!(id),
    do:
      Repo.one(from c in Campaign, where: c.id == ^id, lock: "FOR UPDATE") ||
        Repo.rollback(:not_found)

  defp normalize(id) do
    case Snowflake.cast(id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :invalid_id}
    end
  end
end
