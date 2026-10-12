defmodule AsyncWorlds.Ticks.PlayerDelivery do
  @moduledoc "Pure v3 personal delivery routes, frozen at close and shared by preview/publication."
  alias AsyncWorlds.Discord.Snowflake

  def freeze(characters, campaign, copy_messages) do
    dm = campaign["dm_user_id"]

    routes =
      Enum.flat_map(characters, fn character ->
        owner = character["discord_user_id"]

        primary = %{
          "character_id" => character["id"],
          "recipient_id" => owner || dm,
          "audience" => if(owner, do: "owner", else: "dm_controlled"),
          "label" => if(owner, do: nil, else: "Player: #{character["name"]}")
        }

        copies =
          if (copy_messages and owner) && owner != dm,
            do: [
              %{
                "character_id" => character["id"],
                "recipient_id" => dm,
                "audience" => "dm_copy",
                "label" => "Player copy: #{character["name"]}"
              }
            ],
            else: []

        [primary | copies]
      end)

    %{"copy_messages" => copy_messages, "routes" => routes}
  end

  @doc "Live routing for a new prompt/reminder intent; caller holds the campaign lock."
  def routes(character, campaign) do
    session = AsyncWorlds.Discord.DebugSessions.current(campaign)

    freeze(
      [Map.take(character, [:id, :name, :discord_user_id]) |> stringify()],
      %{"dm_user_id" => campaign.dm_user_id},
      not is_nil(session) and session.copy_messages
    )["routes"]
  end

  def guard(character, campaign, route) do
    %{
      "type" => "character_delivery",
      "guild" => campaign.discord_guild_id,
      "character_id" => character["id"],
      "owner" => character["discord_user_id"],
      "dm" => campaign.dm_user_id,
      "audience" => route["audience"]
    }
  end

  defp stringify(map), do: Map.new(map, fn {key, value} -> {Atom.to_string(key), value} end)

  def valid?(delivery, characters, campaign) do
    is_map(delivery) and is_boolean(delivery["copy_messages"]) and
      match?({:ok, _}, Snowflake.cast(campaign["dm_user_id"])) and
      delivery == freeze(characters, campaign, delivery["copy_messages"]) and
      Enum.all?(delivery["routes"], fn route ->
        match?({:ok, _}, Snowflake.cast(route["recipient_id"]))
      end)
  rescue
    _ -> false
  end
end
