defmodule AsyncWorlds.Ticks.PrivateNotifications do
  @moduledoc "Durable owner-scoped tick prompts. Called within the tick transaction."
  alias AsyncWorlds.{Deliveries, Repo}
  alias AsyncWorlds.Characters.Character
  alias AsyncWorlds.Quests.Submissions
  alias AsyncWorlds.Discord.PlayerContent
  import Ecto.Query

  def opened(campaign, tick) do
    for character <-
          Repo.all(from c in Character, where: c.campaign_id == ^campaign.id, order_by: c.id) do
      case Submissions.notification_state(campaign, character.discord_user_id) do
        {:ok, state} -> enqueue(campaign, tick, character.discord_user_id, state)
        {:error, :inapplicable} -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end
    end
  end

  def remind(guild, actor, request_id) do
    with {:ok, expected} <- AsyncWorlds.Campaigns.authorize_dm(guild, actor),
         {:ok, _request_id} <- AsyncWorlds.Discord.Snowflake.cast(request_id) do
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
          case Submissions.notification_state(campaign, character.discord_user_id) do
            {:ok, %{choice_id: nil} = state} ->
              enqueue(campaign, tick, character.discord_user_id, state, "reminder")
              true

            _ ->
              false
          end
        end)
      end)
    else
      :error -> {:error, :invalid_id}
      error -> error
    end
  end

  @doc false
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

  defp enqueue(campaign, tick, user, state, purpose \\ "prompt") do
    lines =
      ["Tick #{tick.number} is open. Use /quest or /submission to choose or revise."] ++
        PlayerContent.quest_lines(state.quest)

    for {message, index} <- Enum.with_index(PlayerContent.messages(lines, user)) do
      attrs =
        message
        |> Map.put("key", "tick:#{tick.id}:#{purpose}:#{user}:#{index}:opened")
        |> Map.put("guard", %{
          "guild" => campaign.discord_guild_id,
          "actor" => if(purpose == "prompt", do: nil, else: campaign.dm_user_id),
          "missing_only" => purpose != "prompt",
          "identity" => json(state.identity),
          "quest" => json(state.quest)
        })

      case Deliveries.enqueue(campaign.id, tick.id, attrs) do
        {:ok, _} -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end
    end
  end
end
