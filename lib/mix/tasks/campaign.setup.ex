defmodule Mix.Tasks.Campaign.Setup do
  @shortdoc "Creates or reconfigures a campaign for a Discord guild"
  @moduledoc """
  Configures a campaign after `mix ecto.setup` (or `mix ecto.migrate`).

      mix campaign.setup --guild-id 123 --dm-user-id 456 --public-channel-id 789

  All options are required positive unsigned 64-bit Discord IDs. Re-running for
  the same guild updates the DM and public channel without resetting its tick.
  No Discord token or network connection is required. This is a trusted operator
  task, not a player-facing operation.
  """
  use Mix.Task

  alias AsyncWorlds.Campaigns
  alias AsyncWorlds.Campaigns.Campaign

  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          guild_id: [:string, :keep],
          dm_user_id: [:string, :keep],
          public_channel_id: [:string, :keep]
        ]
      )

    if rest != [] or invalid != [] or length(opts) != length(Enum.uniq_by(opts, &elem(&1, 0))) do
      Mix.raise("Expected only --guild-id, --dm-user-id and --public-channel-id, once each")
    end

    attrs = %{
      discord_guild_id: opts[:guild_id],
      dm_user_id: opts[:dm_user_id],
      public_channel_id: opts[:public_channel_id]
    }

    changeset = Campaign.setup_changeset(%Campaign{}, attrs)
    unless changeset.valid?, do: configuration_error!(changeset)

    Mix.Task.run("app.start")

    case Campaigns.setup_campaign(attrs) do
      {:ok, campaign} ->
        Mix.shell().info(
          "Configured campaign #{campaign.id} for guild #{campaign.discord_guild_id} " <>
            "(current tick: #{campaign.current_tick_number})"
        )

      {:error, changeset} ->
        configuration_error!(changeset)
    end
  end

  defp configuration_error!(changeset) do
    errors =
      Enum.map_join(changeset.errors, "; ", fn {field, {message, _}} -> "#{field} #{message}" end)

    Mix.raise("Invalid campaign configuration: #{errors}")
  end
end
