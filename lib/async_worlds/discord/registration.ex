defmodule AsyncWorlds.Discord.Registration do
  @moduledoc "Repeatably replaces this application's command set in the configured development guild."

  alias AsyncWorlds.Campaigns
  alias AsyncWorlds.Discord.{Commands, Dispatcher, Snowflake}

  def register(opts \\ Application.fetch_env!(:async_worlds, :discord)) do
    with {:ok, application_id} <- Snowflake.cast(opts[:application_id]),
         {:ok, guild_id} <- Snowflake.cast(opts[:guild_id]),
         {:ok, _campaign} <- Campaigns.fetch_campaign_by_guild(guild_id) do
      adapter = Keyword.fetch!(opts, :adapter)

      case Dispatcher.safely(:registration, fn ->
             adapter.register_commands(application_id, guild_id, Commands.definitions())
           end) do
        {:ok, commands} when is_list(commands) -> {:ok, commands}
        _ -> {:error, :registration_failed}
      end
    else
      :error -> {:error, :invalid_configuration}
      {:error, reason} -> {:error, reason}
    end
  end
end
