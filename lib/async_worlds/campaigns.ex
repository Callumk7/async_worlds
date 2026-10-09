defmodule AsyncWorlds.Campaigns do
  @moduledoc "Shared campaign configuration, lookup and DM authorization for web and Discord."

  alias AsyncWorlds.Campaigns.Campaign
  alias AsyncWorlds.Discord.Snowflake
  alias AsyncWorlds.Repo

  @doc """
  Creates or updates the campaign for a guild atomically.

  All three IDs are required. Reconfiguration preserves the campaign ID, creation
  time and tick number, including when setup requests race.
  """
  def setup_campaign(attrs) do
    %Campaign{}
    |> Campaign.setup_changeset(attrs)
    |> Repo.insert(
      conflict_target: [:discord_guild_id],
      on_conflict: {:replace, [:dm_user_id, :public_channel_id, :updated_at]},
      returning: true
    )
  end

  @doc "Returns a campaign by guild, distinguishing invalid IDs from missing campaigns."
  def fetch_campaign_by_guild(guild_id) do
    with {:ok, id} <- normalize_id(guild_id) do
      case Repo.get_by(Campaign, discord_guild_id: id) do
        nil -> {:error, :not_found}
        campaign -> {:ok, campaign}
      end
    end
  end

  @doc "Checks a Discord identity against a loaded campaign. Invalid identities fail closed."
  def dm?(%Campaign{dm_user_id: dm_id}, user_id) when not is_nil(dm_id) do
    case Snowflake.cast(user_id) do
      {:ok, id} -> id == dm_id
      :error -> false
    end
  end

  def dm?(_, _), do: false

  @doc """
  Looks up the guild's current configuration and authorizes its DM.

  Returns `{:ok, campaign}` or `{:error, reason}` where reason is `:invalid_id`,
  `:not_found` or `:unauthorized`. Interfaces should call this at protected
  operation boundaries rather than rely on a cached campaign after setup changes.
  """
  def authorize_dm(guild_id, user_id) do
    with {:ok, campaign} <- fetch_campaign_by_guild(guild_id) do
      if dm?(campaign, user_id), do: {:ok, campaign}, else: {:error, :unauthorized}
    end
  end

  defp normalize_id(value) do
    case Snowflake.cast(value) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :invalid_id}
    end
  end
end
