defmodule AsyncWorlds.Quests do
  @moduledoc "Freshly authorized campaign-owned quest authoring and DM progression management."
  import Ecto.Query
  import Ecto.Changeset
  alias AsyncWorlds.{Campaigns, Clocks, Repo}
  alias AsyncWorlds.Campaigns.Campaign
  alias AsyncWorlds.Characters.Character
  alias AsyncWorlds.Discord.Snowflake
  alias AsyncWorlds.Quests.{Definition, Progression, Quest, Revision, Rules, Submissions}

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

  def assign(campaign, dm_id, character_id, revision_id) do
    manage(campaign, dm_id, fn current ->
      mutable!(current)
      assign!(current.id, character_id, revision_id)
    end)
  end

  def swap(campaign, dm_id, character_id, revision_id) do
    manage(campaign, dm_id, fn current ->
      mutable!(current)
      fetch!(Character, current.id, character_id)
      Submissions.invalidate_open(current.id, character_id)

      if active = active(current.id, character_id),
        do: Repo.update!(change(active, status: :ended))

      assign!(current.id, character_id, revision_id)
    end)
  end

  def end_quest(campaign, dm_id, progression_id) do
    manage(campaign, dm_id, fn current ->
      mutable!(current)
      progression = fetch!(Progression, current.id, progression_id)
      if progression.status != :active, do: Repo.rollback(:not_active)
      Submissions.invalidate_open(current.id, progression.character_id)
      Repo.update!(change(progression, status: :ended))
    end)
  end

  def move(campaign, dm_id, progression_id, node_id) do
    manage(campaign, dm_id, fn current ->
      mutable!(current)
      progression = fetch!(Progression, current.id, progression_id)
      if progression.status != :active, do: Repo.rollback(:not_active)
      revision = fetch!(Revision, current.id, progression.revision_id)
      node = Rules.node(revision.definition, node_id) || Repo.rollback(:invalid_node)

      if progression.node_id == node_id do
        progression
      else
        Submissions.invalidate_open(current.id, progression.character_id)

        Repo.update!(
          change(progression,
            node_id: node_id,
            status: status(node),
            position_version: progression.position_version + 1
          )
        )
      end
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
    with {:ok, user_id} <- normalize(verified_user_id),
         {:ok, expected} <- Campaigns.fetch_campaign_by_guild(guild_id) do
      Repo.transaction(fn ->
        current = lock!(expected.id)
        if current.discord_guild_id != expected.discord_guild_id, do: Repo.rollback(:not_found)

        character =
          Repo.get_by(Character, campaign_id: current.id, discord_user_id: user_id) ||
            Repo.rollback(:not_found)

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
