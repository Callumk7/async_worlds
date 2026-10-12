defmodule Mix.Tasks.Clock.Create do
  use Mix.Task
  @shortdoc "Creates a campaign clock through freshly authorized shared operations"
  @moduledoc """
  Trusted bootstrap command (creation is not idempotent):

      mix clock.create --guild-id 123 --dm-user-id 456 --name "Harbor alarm" --segments 6 --visibility hidden

  Prints the clock ID for quest import bindings. No SQL or Discord connection.
  """
  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          guild_id: [:string, :keep],
          dm_user_id: [:string, :keep],
          name: [:string, :keep],
          segments: [:integer, :keep],
          visibility: [:string, :keep]
        ]
      )

    required = [:guild_id, :dm_user_id, :name, :segments]

    unless rest == [] and invalid == [] and
             Enum.all?(required, &(length(Keyword.get_values(opts, &1)) == 1)) and
             length(opts) == length(Enum.uniq_by(opts, &elem(&1, 0))),
           do:
             Mix.raise(
               "Expected --guild-id, --dm-user-id, --name, --segments and optional --visibility"
             )

    Mix.Task.run("app.start")

    with {:ok, campaign} <- AsyncWorlds.Campaigns.fetch_campaign_by_guild(opts[:guild_id]),
         {:ok, clock} <-
           AsyncWorlds.Quests.create_clock(campaign, opts[:dm_user_id], %{
             name: opts[:name],
             segments: opts[:segments],
             visibility: opts[:visibility] || "public"
           }) do
      Mix.shell().info("Created clock #{clock.id}: #{clock.name}")
    else
      {:error, reason} -> Mix.raise("Clock creation rejected: #{inspect(reason)}")
    end
  end
end
