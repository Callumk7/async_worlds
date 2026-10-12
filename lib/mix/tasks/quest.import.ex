defmodule Mix.Tasks.Quest.Import do
  use Mix.Task
  @shortdoc "Imports a versioned quest JSON document atomically (trusted operator)"
  @moduledoc """
  Trusted operator only. Calls the same freshly authorized domain operation as
  future DM interfaces. Clock aliases in JSON bind to existing campaign clocks:

      mix quest.import --guild-id 123 --dm-user-id 456 --file priv/quests/harbor.json --clock alarm=1

  Repeat --clock for additional aliases. No network or SQL is used.
  """
  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [guild_id: :string, dm_user_id: :string, file: :string, clock: [:string, :keep]]
      )

    required = [:guild_id, :dm_user_id, :file]

    unless rest == [] and invalid == [] and
             Enum.all?(required, &(length(Keyword.get_values(opts, &1)) == 1)),
           do:
             Mix.raise(
               "Expected --guild-id, --dm-user-id, --file and optional repeated --clock alias=id"
             )

    bindings =
      Enum.reduce(Keyword.get_values(opts, :clock), %{}, fn binding, acc ->
        case String.split(binding, "=") do
          [name, raw_id] ->
            case Integer.parse(raw_id) do
              {id, ""} when id > 0 ->
                if Map.has_key?(acc, name) or not AsyncWorlds.Quests.Definition.id?(name),
                  do: Mix.raise("Duplicate or invalid clock alias: #{name}")

                Map.put(acc, name, id)

              _ ->
                Mix.raise("Invalid clock binding: #{binding}")
            end

          _ ->
            Mix.raise("Expected clock alias=id: #{binding}")
        end
      end)

    json =
      case File.read(opts[:file]) do
        {:ok, json} -> json
        {:error, reason} -> Mix.raise("Cannot read #{opts[:file]}: #{inspect(reason)}")
      end

    Mix.Task.run("app.start")

    with {:ok, campaign} <- AsyncWorlds.Campaigns.fetch_campaign_by_guild(opts[:guild_id]),
         {:ok, results} <-
           AsyncWorlds.Quests.import_json(campaign, opts[:dm_user_id], json, clock_refs: bindings) do
      Enum.each(results, fn result ->
        r = result.revision
        Mix.shell().info("#{result.action}: quest #{r.quest_id}, revision #{r.id} (#{r.number})")
      end)
    else
      {:error, errors} when is_list(errors) ->
        Mix.raise(Enum.map_join(errors, "\n", &"#{&1.path}: #{&1.message}"))

      {:error, reason} ->
        Mix.raise("Import rejected: #{inspect(reason)}")
    end
  end
end
