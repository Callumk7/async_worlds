defmodule AsyncWorlds.Journals do
  @moduledoc "Persistent character-owned journals, independent of ticks and Discord delivery."
  import Ecto.Query
  alias AsyncWorlds.{Campaigns, PlayerAccess, Repo}
  alias AsyncWorlds.Campaigns.Campaign
  alias AsyncWorlds.Characters.Character
  alias AsyncWorlds.Discord.{DebugSessions, Snowflake}
  alias AsyncWorlds.Journals.{CreationReceipt, Entry}

  @max_id 9_223_372_036_854_775_807
  @page_size 10

  def begin_creation(context, request_id, visibility \\ "private") do
    with {:ok, request_id} <- Snowflake.cast(request_id),
         {:ok, visibility} <- visibility(visibility) do
      player(context, fn campaign, character ->
        binding = binding(campaign, character, context)

        case Repo.get_by(CreationReceipt, campaign_id: campaign.id, request_id: request_id) do
          nil ->
            %CreationReceipt{
              campaign_id: campaign.id,
              character_id: character.id,
              request_id: request_id,
              actor_id: actor(context),
              binding: binding,
              origin: if(is_map(context.access), do: :dm_persona, else: :player),
              visibility: visibility,
              expires_at: DateTime.add(DateTime.utc_now(), 900, :second)
            }
            |> Repo.insert!()
            |> receipt_payload()

          receipt ->
            unless receipt.binding == binding and receipt.visibility == visibility,
              do: Repo.rollback(:stale_component)

            receipt_payload(receipt)
        end
      end)
    end
  end

  def open_creation(context, receipt_id) do
    player(context, fn campaign, character ->
      receipt = receipt!(campaign, character, context, receipt_id)
      pending!(receipt)
      receipt_payload(receipt)
    end)
  end

  def submit(context, receipt_id, attrs) do
    player(context, fn campaign, character ->
      receipt = receipt!(campaign, character, context, receipt_id)

      case receipt.state do
        state when state in [:completed, :deleted] ->
          receipt_payload(receipt)

        _ ->
          pending!(receipt)

          entry = %Entry{
            campaign_id: campaign.id,
            character_id: character.id,
            receipt_id: receipt.id,
            author_discord_user_id: receipt.actor_id,
            origin: receipt.origin,
            visibility: receipt.visibility
          }

          case Repo.insert(Entry.changeset(entry, attrs), log: false) do
            {:ok, entry} ->
              receipt
              |> Ecto.Changeset.change(state: :completed, entry_id: entry.id)
              |> Repo.update!()
              |> receipt_payload()

            {:error, _changeset} ->
              # Never return a draft-bearing changeset to the interaction/logger boundary.
              Repo.rollback(:invalid_journal_input)
          end
      end
    end)
  end

  def cancel_creation(context, receipt_id) do
    player(context, fn campaign, character ->
      receipt = receipt!(campaign, character, context, receipt_id)
      pending!(receipt)
      receipt |> Ecto.Changeset.change(state: :canceled) |> Repo.update!() |> receipt_payload()
    end)
  end

  def list_entries(context, scope \\ :mine, character_id \\ nil, cursor \\ nil) do
    with {:ok, cursor} <- cursor(cursor) do
      read(
        context,
        scope == :character or (scope == :public and dm_access?(context)),
        fn campaign, character ->
          query = visible_query(campaign, character)

          query =
            case {scope, character_id} do
              {:mine, nil} when not is_nil(character) ->
                where(query, [e], e.character_id == ^character.id)

              {:public, nil} ->
                where(query, [e], e.visibility == :public)

              {:character, id} when is_nil(character) ->
                id = id!(id)

                unless Repo.get_by(Character, campaign_id: campaign.id, id: id),
                  do: Repo.rollback(:not_found)

                where(query, [e], e.character_id == ^id)

              _ ->
                Repo.rollback(:unauthorized)
            end

          Map.put(page(query, cursor), :binding, binding(campaign, character, context))
        end
      )
    end
  end

  def get_entry(context, entry_id) do
    read(context, dm_access?(context), fn campaign, character ->
      entry_id = id!(entry_id)

      visible_query(campaign, character)
      |> where([e], e.id == ^entry_id)
      |> join(:inner, [e], c in Character,
        on: c.id == e.character_id and c.campaign_id == e.campaign_id
      )
      |> select([e, c], %{
        id: e.id,
        title: e.title,
        body: e.body,
        visibility: e.visibility,
        character_id: e.character_id,
        character: c.name,
        inserted_at: e.inserted_at,
        author_discord_user_id: e.author_discord_user_id,
        origin: e.origin
      })
      |> Repo.one(log: false)
      |> case do
        nil ->
          Repo.rollback(:not_found)

        entry ->
          entry
          |> Map.put(:can_delete?, is_nil(character) or entry.character_id == character.id)
          |> Map.put(:binding, binding(campaign, character, context))
      end
    end)
  end

  def prepare_delete(context, entry_id) do
    read(context, dm_access?(context), fn campaign, character ->
      entry = deletable!(campaign, character, entry_id)

      %{
        id: entry.id,
        title: entry.title,
        binding: Map.put(binding(campaign, character, context), "target", entry.id)
      }
    end)
  end

  # expected_binding comes from an authenticated, target-specific confirmation control.
  def delete_entry(context, entry_id, expected_binding) do
    read(context, dm_access?(context), fn campaign, character ->
      id = id!(entry_id)

      unless expected_binding == Map.put(binding(campaign, character, context), "target", id),
        do: Repo.rollback(:stale_component)

      receipt = Repo.get_by(CreationReceipt, campaign_id: campaign.id, entry_id: id)

      unless receipt && (is_nil(character) or receipt.character_id == character.id),
        do: Repo.rollback(:not_found)

      case receipt.state do
        :deleted ->
          :already_deleted

        :completed ->
          entry = Repo.get_by(Entry, [campaign_id: campaign.id, id: id], log: false)
          if entry, do: Repo.delete!(entry, log: false)
          receipt |> Ecto.Changeset.change(state: :deleted) |> Repo.update!()
          if entry, do: :deleted, else: :already_deleted

        _ ->
          Repo.rollback(:not_found)
      end
    end)
  end

  @doc "Fresh control binding, evaluated under the same campaign lock as the operation."
  def control_binding(context, dm? \\ false) do
    read(context, dm?, fn campaign, character -> binding(campaign, character, context) end)
  end

  defp player(context, fun) do
    PlayerAccess.run(context.campaign.discord_guild_id, context.access, fn campaign, character ->
      # A raw DM identity must not bypass a currently selected player persona.
      enforce_role!(campaign, context, false)
      fun.(campaign, character)
    end)
  end

  defp read(context, true, fun) do
    with {:ok, actor} <- Snowflake.cast(actor(context)) do
      Repo.transaction(fn ->
        campaign =
          Repo.one(from c in Campaign, where: c.id == ^context.campaign.id, lock: "FOR UPDATE")

        unless campaign && Campaigns.dm?(campaign, actor), do: Repo.rollback(:unauthorized)

        unless configuration(campaign) == configuration(context.campaign),
          do: Repo.rollback(:stale_component)

        enforce_role!(campaign, context, true)
        fun.(campaign, nil)
      end)
    end
  end

  defp read(context, false, fun), do: player(context, fun)

  defp enforce_role!(campaign, context, dm?) do
    session = if Campaigns.dm?(campaign, actor(context)), do: DebugSessions.current(campaign)
    persona? = not is_nil(session) and session.enabled and session.role == :player

    if dm? do
      unless not persona? and not is_map(context.access), do: Repo.rollback(:unauthorized)
    else
      if persona? and not is_map(context.access), do: Repo.rollback(:stale_component)
    end
  end

  defp dm_access?(context), do: context.role == :dm and not is_map(context.access)
  defp actor(%{access: %{actor_id: actor}}), do: actor
  defp actor(context), do: context.access

  defp binding(campaign, character, context) do
    session = if Campaigns.dm?(campaign, actor(context)), do: DebugSessions.current(campaign)

    %{
      "campaign" => campaign.id,
      "guild" => campaign.discord_guild_id,
      "dm" => campaign.dm_user_id,
      "channel" => campaign.public_channel_id,
      "actor" => actor(context),
      "character" => character && character.id,
      "owner" => character && character.discord_user_id,
      "version" => character && character.state_version,
      "generation" =>
        if(Campaigns.dm?(campaign, actor(context)),
          do: if(session, do: session.generation, else: 0),
          else: nil
        ),
      "persona" => is_map(context.access)
    }
  end

  defp configuration(c), do: Map.take(c, [:discord_guild_id, :dm_user_id, :public_channel_id])

  defp receipt!(campaign, character, context, receipt_id) do
    with {:ok, id} <- Ecto.UUID.cast(receipt_id),
         %CreationReceipt{} = receipt <-
           Repo.get_by(CreationReceipt, campaign_id: campaign.id, id: id),
         true <- receipt.binding == binding(campaign, character, context) do
      receipt
    else
      _ -> Repo.rollback(:stale_component)
    end
  end

  defp pending!(receipt) do
    unless receipt.state == :pending and
             DateTime.compare(receipt.expires_at, DateTime.utc_now()) == :gt,
           do: Repo.rollback(:stale_component)
  end

  defp receipt_payload(r) do
    state =
      if r.state == :completed and
           not Repo.exists?(
             from(e in Entry, where: e.id == ^r.entry_id and e.campaign_id == ^r.campaign_id)
           ), do: :deleted, else: r.state

    %{id: r.id, state: state, entry_id: r.entry_id, visibility: r.visibility}
  end

  defp visible_query(campaign, nil), do: from(e in Entry, where: e.campaign_id == ^campaign.id)

  defp visible_query(campaign, character) do
    from e in Entry,
      where:
        e.campaign_id == ^campaign.id and
          (e.visibility == :public or e.character_id == ^character.id)
  end

  defp deletable!(campaign, character, entry_id) do
    entry = Repo.get_by(Entry, [campaign_id: campaign.id, id: id!(entry_id)], log: false)

    unless entry && (is_nil(character) or entry.character_id == character.id),
      do: Repo.rollback(:not_found)

    entry
  end

  defp page(query, cursor) do
    ceiling =
      if cursor,
        do: cursor.ceiling,
        else: Repo.one(from e in query, order_by: [desc: e.id], limit: 1, select: e.id) || 0

    bounded = where(query, [e], e.id <= ^ceiling)

    window =
      case cursor do
        %{direction: :next, anchor: anchor} ->
          from e in bounded, where: e.id < ^anchor, order_by: [desc: e.id]

        %{direction: :previous, anchor: anchor} ->
          from e in bounded, where: e.id > ^anchor, order_by: [asc: e.id]

        nil ->
          from e in bounded, order_by: [desc: e.id]
      end

    entries =
      window
      |> join(:inner, [e], c in Character,
        on: c.id == e.character_id and c.campaign_id == e.campaign_id
      )
      |> select([e, c], %{
        id: e.id,
        title: e.title,
        character: c.name,
        visibility: e.visibility,
        inserted_at: e.inserted_at
      })
      |> limit(^(@page_size + 1))
      |> Repo.all(log: false)
      |> Enum.take(@page_size)

    entries = if cursor && cursor.direction == :previous, do: Enum.reverse(entries), else: entries
    first = List.first(entries)
    last = List.last(entries)

    previous =
      if first && Repo.exists?(where(bounded, [e], e.id > ^first.id)),
        do: %{direction: :previous, anchor: first.id, ceiling: ceiling}

    next =
      if last && Repo.exists?(where(bounded, [e], e.id < ^last.id)),
        do: %{direction: :next, anchor: last.id, ceiling: ceiling}

    # An emptied window can always navigate back using its original boundary.
    previous =
      if entries == [] && cursor && cursor.direction == :next,
        do: %{cursor | direction: :previous, anchor: cursor.anchor - 1},
        else: previous

    next =
      if entries == [] && cursor && cursor.direction == :previous,
        do: %{cursor | direction: :next, anchor: cursor.anchor + 1},
        else: next

    %{entries: entries, previous: previous, next: next}
  end

  defp cursor(nil), do: {:ok, nil}

  defp cursor(%{direction: direction, anchor: anchor, ceiling: ceiling} = cursor)
       when direction in [:next, :previous] and is_integer(anchor) and anchor >= 0 and
              anchor <= @max_id and is_integer(ceiling) and ceiling <= @max_id and
              ((direction == :next and anchor > 0 and ceiling >= anchor) or
                 (direction == :previous and ceiling > anchor)) and map_size(cursor) == 3,
       do: {:ok, cursor}

  defp cursor(_), do: {:error, :stale_component}

  defp id!(value) do
    case Ecto.Type.cast(:id, value) do
      {:ok, id} when is_integer(id) and id > 0 and id <= @max_id -> id
      _ -> Repo.rollback(:not_found)
    end
  end

  defp visibility(value) when value in [:private, "private"], do: {:ok, :private}
  defp visibility(value) when value in [:public, "public"], do: {:ok, :public}
  defp visibility(_), do: {:error, :invalid_journal_input}
end
