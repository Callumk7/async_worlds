defmodule Mix.Tasks.Discord.RegisterCommands do
  @shortdoc "Replaces milestone-1 slash commands in the configured development guild"
  @moduledoc """
  Registers `/clocks`, `/tick open`, `/tick close`, `/tick status` and `/admin`.

      DISCORD_ENABLED=true mix discord.register_commands

  Requires DISCORD_BOT_TOKEN, DISCORD_APPLICATION_ID and DISCORD_GUILD_ID, plus
  an existing campaign configured with `mix campaign.setup`. Takes no arguments
  to prevent accidentally targeting another guild. This overwrites all of this
  application's commands in that guild; it never registers global commands.
  """
  use Mix.Task

  @impl true
  def run(args) do
    if args != [], do: Mix.raise("discord.register_commands takes no arguments")

    Mix.Task.run("app.config")
    opts = Application.fetch_env!(:async_worlds, :discord)
    unless opts[:enabled], do: Mix.raise("Set DISCORD_ENABLED=true to register Discord commands")

    Mix.Task.run("app.start")

    case AsyncWorlds.Discord.Registration.register(opts) do
      {:ok, commands} ->
        Mix.shell().info("Registered #{length(commands)} commands in guild #{opts[:guild_id]}")

      {:error, :not_found} ->
        Mix.raise("No campaign for DISCORD_GUILD_ID; run mix campaign.setup first")

      {:error, :invalid_configuration} ->
        Mix.raise("DISCORD_APPLICATION_ID and DISCORD_GUILD_ID must be valid Discord IDs")

      {:error, _} ->
        Mix.raise(
          "Discord command registration failed; check the token, installation and permissions"
        )
    end
  end
end
