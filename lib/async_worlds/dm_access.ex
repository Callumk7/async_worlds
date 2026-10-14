defmodule AsyncWorlds.DMAccess do
  @moduledoc """
  Shared actor-aware boundary for trusted interfaces serving DM operations.

  Scope contains a campaign and a verified discord_user_id, never an identity
  copied from request parameters. Authorization and the operation share the
  campaign row lock, so reconfiguration cannot race an authorized mutation.
  Callbacks return {:ok, value} or {:error, reason}; results are not nested.
  """
  import Ecto.Query
  alias AsyncWorlds.{Campaigns, Repo}
  alias AsyncWorlds.Campaigns.Campaign
  alias AsyncWorlds.Discord.Snowflake

  def run(%{campaign: %Campaign{id: id} = expected, discord_user_id: actor}, fun)
      when is_integer(id) and id > 0 and is_function(fun, 2) do
    with {:ok, actor} <- normalize(actor) do
      Repo.transaction(fn ->
        current = Repo.one(from c in Campaign, where: c.id == ^id, lock: "FOR UPDATE")
        unless current, do: Repo.rollback(:not_found)
        unless Campaigns.dm?(current, actor), do: Repo.rollback(:unauthorized)

        fields = [:discord_guild_id, :dm_user_id, :public_channel_id]

        if Map.take(current, fields) != Map.take(expected, fields),
          do: Repo.rollback(:stale_campaign)

        case fun.(current, actor) do
          {:ok, value} -> value
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  def run(_, _), do: {:error, :invalid_scope}

  @doc "Audit attribution generated from verified identity and a trusted interface label."
  def source(actor, origin) when origin in [:web, :http, :discord, :operator],
    do: {:ok, "dm:#{origin}:#{actor}"}

  def source(_, _), do: {:error, :invalid_source}

  defp normalize(actor) do
    case Snowflake.cast(actor) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :invalid_id}
    end
  end
end
