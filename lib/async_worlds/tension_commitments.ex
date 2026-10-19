defmodule AsyncWorlds.TensionCommitments do
  @moduledoc "Private broad intentions, never outcomes. All reads and writes freshly authorize under the lifecycle campaign lock."
  import Ecto.Query
  alias AsyncWorlds.{DMAccess, PlayerAccess, Repo, Ticks}
  alias AsyncWorlds.Characters.Character
  alias AsyncWorlds.Tensions.{Commitment, Tension}

  @fields [:tick_id, :tension_id, :character_id, :version, :state, :intention, :approach, :ready]

  def change(guild, access, tick_id, tension_id, version, operation, attrs \\ %{}) do
    PlayerAccess.run(guild, access, fn campaign, character ->
      tick = tick!(campaign.id, tick_id)
      unless tick.status == :open, do: Repo.rollback(:tick_closed)
      tension = Repo.get_by(Tension, campaign_id: campaign.id, id: tension_id)
      unless tension, do: Repo.rollback(:not_found)

      current =
        Repo.get_by(Commitment,
          tick_id: tick.id,
          tension_id: tension.id,
          character_id: character.id
        )

      entry =
        current ||
          %Commitment{
            campaign_id: campaign.id,
            tick_id: tick.id,
            tension_id: tension.id,
            character_id: character.id
          }

      unless accepts_operation?(tension, current, operation), do: Repo.rollback(:not_found)

      unless is_integer(version) and version == entry.version,
        do: Repo.rollback(:stale_commitment)

      changes = changes!(entry, operation, attrs)
      changeset = Ecto.Changeset.change(entry, Keyword.put(changes, :version, version + 1))
      result = if current, do: Repo.update!(changeset), else: Repo.insert!(changeset)
      PlayerAccess.audit(access, campaign.id, :tension_commitment)
      project(result)
    end)
  end

  def player_state(guild, access, tick_id) do
    PlayerAccess.run(guild, access, fn campaign, character ->
      tick = tick!(campaign.id, tick_id)

      %{
        tick_id: tick.id,
        status: tick.status,
        participation: participation(campaign.id, tick, [character])
      }
    end)
  end

  def dm_state(scope, tick_id) do
    DMAccess.run(scope, fn campaign, _actor ->
      tick = tick!(campaign.id, tick_id)

      {:ok,
       %{
         tick_id: tick.id,
         status: tick.status,
         participation: participation(campaign.id, tick, :all)
       }}
    end)
  end

  @doc false
  # Called only by close while holding the campaign lock. The snapshot is the
  # immutable authority after close; no delivery status participates in this read.
  def freeze(campaign_id, tick_id) do
    roster(campaign_id, tick_id, characters(campaign_id))
    |> Jason.encode!()
    |> Jason.decode!()
  end

  defp participation(campaign_id, %{status: :open} = tick, :all),
    do: roster(campaign_id, tick.id, characters(campaign_id))

  defp participation(campaign_id, %{status: :open} = tick, characters),
    do: roster(campaign_id, tick.id, characters)

  defp participation(campaign_id, tick, characters) do
    {:ok, snapshot} = Ticks.fetch_snapshot(campaign_id, tick.id)
    ids = if characters == :all, do: :all, else: Enum.map(characters, & &1.id)

    (snapshot.data["tension_commitments"] || [])
    |> Enum.filter(&(ids == :all or &1["character_id"] in ids))
    |> Enum.map(fn row ->
      %{
        character_id: row["character_id"],
        commitments:
          Enum.map(row["commitments"], fn entry ->
            Map.new(@fields, &{&1, entry[Atom.to_string(&1)]})
          end)
      }
    end)
  end

  defp roster(campaign_id, tick_id, characters) do
    entries =
      Repo.all(
        from e in Commitment, where: e.campaign_id == ^campaign_id and e.tick_id == ^tick_id
      )

    tensions =
      Repo.all(
        from t in Tension,
          where: t.campaign_id == ^campaign_id and t.audience == :public and t.status == :ongoing,
          order_by: t.id
      )

    for character <- characters do
      owned = Enum.filter(entries, &(&1.character_id == character.id))
      ids = Enum.sort(Enum.uniq(Enum.map(tensions, & &1.id) ++ Enum.map(owned, & &1.tension_id)))

      %{
        character_id: character.id,
        commitments:
          Enum.map(ids, fn id ->
            case Enum.find(owned, &(&1.tension_id == id)) do
              nil ->
                %{
                  tick_id: tick_id,
                  tension_id: id,
                  character_id: character.id,
                  version: 0,
                  state: :absent,
                  intention: nil,
                  approach: nil,
                  ready: false
                }

              entry ->
                project(entry)
            end
          end)
      }
    end
  end

  defp characters(id),
    do: Repo.all(from c in Character, where: c.campaign_id == ^id, order_by: c.id)

  defp project(entry), do: Map.take(entry, @fields)

  defp tick!(campaign_id, tick_id) do
    case Ticks.fetch_tick(campaign_id, tick_id) do
      {:ok, tick} -> tick
      _ -> Repo.rollback(:not_found)
    end
  end

  defp accepts_operation?(_tension, %Commitment{}, :withdraw), do: true
  defp accepts_operation?(%{audience: :public, status: :ongoing}, _current, _operation), do: true
  defp accepts_operation?(_, _, _), do: false

  defp changes!(entry, :edit, attrs) when is_map(attrs) do
    intention = Map.get(attrs, "intention")
    approach = Map.get(attrs, "approach", entry.approach)

    unless valid_text?(intention, true) and valid_text?(approach, false),
      do: Repo.rollback(:invalid_commitment)

    [intention: String.trim(intention), approach: approach, state: :unresolved, ready: false]
  end

  defp changes!(%{state: state, intention: text}, :confirm, _)
       when state in [:unresolved, :confirmed] and is_binary(text),
       do: [state: :confirmed, ready: false]

  defp changes!(%{state: :confirmed}, :ready, _), do: [ready: true]

  defp changes!(_entry, :withdraw, _),
    do: [state: :withdrawn, intention: nil, approach: nil, ready: false]

  defp changes!(_, _, _), do: Repo.rollback(:invalid_commitment)

  defp valid_text?(nil, false), do: true

  defp valid_text?(text, required) when is_binary(text) do
    String.valid?(text) and not String.contains?(text, <<0>>) and byte_size(text) <= 8000 and
      length(String.codepoints(text)) <= 2000 and (not required or String.trim(text) != "")
  end

  defp valid_text?(_, _), do: false
end
