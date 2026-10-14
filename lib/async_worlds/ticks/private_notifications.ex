defmodule AsyncWorlds.Ticks.PrivateNotifications do
  @moduledoc "Durable owner-scoped tick prompts. Called within the tick transaction."
  alias AsyncWorlds.{Deliveries, Repo}
  alias AsyncWorlds.Characters.Character
  alias AsyncWorlds.Quests.Submissions
  alias AsyncWorlds.Discord.PlayerContent
  alias AsyncWorlds.Ticks.PlayerDelivery
  import Ecto.Query

  def opened(campaign, tick) do
    for character <-
          Repo.all(from c in Character, where: c.campaign_id == ^campaign.id, order_by: c.id) do
      case Submissions.notification_state(campaign, character) do
        {:ok, state} -> enqueue(campaign, tick, character, state)
        {:error, :inapplicable} -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end
    end
  end

  @doc "Request keys are transport-neutral; intents remain deduplicated per tick/subject/route, not per request."
  def remind(guild, actor, request_id) do
    with {:ok, expected} <- AsyncWorlds.Campaigns.authorize_dm(guild, actor),
         :ok <- request_key(request_id) do
      Repo.transaction(fn ->
        campaign =
          Repo.one!(
            from c in AsyncWorlds.Campaigns.Campaign,
              where: c.id == ^expected.id,
              lock: "FOR UPDATE"
          )

        unless campaign.dm_user_id == expected.dm_user_id and
                 campaign.discord_guild_id == expected.discord_guild_id,
               do: Repo.rollback(:unauthorized)

        tick = AsyncWorlds.Ticks.active_tick(campaign.id) || Repo.rollback(:no_tick)
        if tick.status != :open, do: Repo.rollback(:tick_closed)

        characters =
          Repo.all(from c in Character, where: c.campaign_id == ^campaign.id, order_by: c.id)

        Enum.count(characters, fn character ->
          case Submissions.notification_state(campaign, character) do
            {:ok, %{choice_id: nil} = state} ->
              enqueue(campaign, tick, character, state, "reminder")
              true

            _ ->
              false
          end
        end)
      end)
    end
  end

  defp request_key(key) when is_binary(key) and byte_size(key) in 1..200 do
    if String.valid?(key) and String.trim(key) != "" and not String.contains?(key, <<0>>),
      do: :ok,
      else: {:error, :invalid_idempotency_key}
  end

  defp request_key(_), do: {:error, :invalid_idempotency_key}

  @doc false
  def applicable?(%{guard: %{"type" => type} = guard} = delivery, campaign)
      when type in ["character_delivery", "character_prompt"] do
    character = Repo.get_by(Character, campaign_id: campaign.id, id: guard["character_id"])

    valid_route =
      character && guard["guild"] == campaign.discord_guild_id &&
        character.discord_user_id == guard["owner"] &&
        case guard["audience"] do
          "owner" ->
            not is_nil(character.discord_user_id) and
              delivery.recipient_id == character.discord_user_id

          "dm_controlled" ->
            is_nil(character.discord_user_id) and guard["dm"] == campaign.dm_user_id and
              delivery.recipient_id == campaign.dm_user_id

          "dm_copy" ->
            not is_nil(character.discord_user_id) and
              character.discord_user_id != campaign.dm_user_id and
              guard["dm"] == campaign.dm_user_id and delivery.recipient_id == campaign.dm_user_id

          _ ->
            false
        end

    if valid_route and type == "character_prompt" do
      with true <- is_nil(guard["actor"]) or guard["actor"] == campaign.dm_user_id,
           {:ok, state} <- Submissions.notification_state(campaign, character),
           true <- state.open and state.identity.tick_id == delivery.tick_id,
           true <-
             json(state.identity) == guard["identity"] and json(state.quest) == guard["quest"],
           true <- not guard["missing_only"] or is_nil(state.choice_id) do
        true
      else
        _ -> false
      end
    else
      valid_route == true
    end
  end

  def applicable?(
        %{guard: %{"type" => "published_player", "character_id" => id, "guild" => guild}} =
          delivery,
        campaign
      ) do
    guild == campaign.discord_guild_id and
      Repo.exists?(
        from c in Character,
          where:
            c.id == ^id and c.campaign_id == ^campaign.id and
              c.discord_user_id == ^delivery.recipient_id
      )
  end

  def applicable?(delivery, campaign) do
    guard = delivery.guard

    with true <- guard["guild"] == campaign.discord_guild_id,
         true <- is_nil(guard["actor"]) or guard["actor"] == campaign.dm_user_id,
         {:ok, state} <- Submissions.notification_state(campaign, delivery.recipient_id),
         true <- state.open and state.identity.tick_id == delivery.tick_id,
         true <-
           json(state.identity) == guard["identity"] and json(state.quest) == guard["quest"],
         true <- not guard["missing_only"] or is_nil(state.choice_id) do
      true
    else
      _ -> false
    end
  end

  defp json(value), do: value |> Jason.encode!() |> Jason.decode!()

  defp enqueue(campaign, tick, character, state, purpose \\ "prompt") do
    lines =
      ["Tick #{tick.number} is open. Use /quest or /submission to choose or revise."] ++
        PlayerContent.quest_lines(state.quest)

    for route <- PlayerDelivery.routes(character, campaign),
        labelled = if(route["label"], do: [route["label"] | lines], else: lines),
        {message, index} <-
          Enum.with_index(PlayerContent.messages(labelled, route["recipient_id"])) do
      # An owner ID may have moved to another character during this tick.
      # Preserve identifiable old intents; never reuse another subject's key.
      {key, existing} = intent_key(campaign, tick, character, route, purpose, index)

      routing =
        PlayerDelivery.guard(
          %{"id" => character.id, "discord_user_id" => character.discord_user_id},
          campaign,
          route
        )

      attrs =
        message
        |> Map.put("key", key)
        |> Map.put(
          "guard",
          Map.merge(routing, %{
            "type" => "character_prompt",
            "guild" => campaign.discord_guild_id,
            "actor" => if(purpose == "prompt", do: nil, else: campaign.dm_user_id),
            "missing_only" => purpose != "prompt",
            "identity" => json(state.identity),
            "quest" => json(state.quest)
          })
        )

      attrs = compatible_legacy_guard(attrs, existing)

      case Deliveries.enqueue(campaign.id, tick.id, attrs) do
        {:ok, _} -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end
    end
  end

  defp intent_key(campaign, tick, character, route, purpose, index) do
    scoped =
      "tick:#{tick.id}:#{purpose}:character:#{character.id}:#{route["audience"]}:#{route["recipient_id"]}:#{index}:opened"

    if route["audience"] == "owner" do
      legacy = "tick:#{tick.id}:#{purpose}:#{route["recipient_id"]}:#{index}:opened"

      existing =
        Repo.get_by(AsyncWorlds.Deliveries.Delivery, campaign_id: campaign.id, key: legacy)

      if is_nil(existing) or same_subject?(existing.guard, campaign.id, character.id),
        do: {legacy, existing},
        else: {scoped, nil}
    else
      {scoped, nil}
    end
  end

  defp same_subject?(%{"character_id" => id}, _, character_id), do: id == character_id

  defp same_subject?(%{"identity" => %{"progression_id" => id}}, campaign_id, character_id) do
    Repo.exists?(
      from p in AsyncWorlds.Quests.Progression,
        where: p.id == ^id and p.campaign_id == ^campaign_id and p.character_id == ^character_id
    )
  end

  defp same_subject?(_, _, _), do: false

  # ENG-21 intents lack the newer routing fields. Reuse only an exactly matching
  # legacy guard; enqueue still checks content and all other immutable fields.
  # This preserves sent/failed/ambiguous state without implicit retries.
  defp compatible_legacy_guard(attrs, %{guard: guard}) do
    fields = ~w(actor guild identity missing_only quest)

    if Enum.sort(Map.keys(guard)) == fields and Map.take(attrs["guard"], fields) == guard,
      do: Map.put(attrs, "guard", guard),
      else: attrs
  end

  defp compatible_legacy_guard(attrs, _), do: attrs
end
