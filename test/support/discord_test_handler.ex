defmodule AsyncWorlds.Discord.TestHandler do
  @moduledoc false
  import Ecto.Query
  alias AsyncWorlds.{Campaigns.Campaign, Repo}

  def execute(:tick_open, context) do
    # A minimal stand-in for a future domain transition, not a Discord rule:
    # different interaction IDs still cannot repeat the protected transition.
    query = from c in Campaign, where: c.id == ^context.campaign.id and c.current_tick_number == 0

    case Repo.update_all(query, set: [current_tick_number: 1]) do
      {1, _} -> {:ok, "Opened"}
      {0, _} -> {:error, :invalid_transition}
    end
  end

  def execute(_command, context),
    do:
      {:ok,
       "Authorized campaign #{context.campaign.id}, user #{context.user_id}, interaction #{context.interaction_id}"}
end
