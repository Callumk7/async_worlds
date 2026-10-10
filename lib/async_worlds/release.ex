defmodule AsyncWorlds.Release do
  @moduledoc "Operator commands for releases. Starts only the repository, never Discord or queues."
  @app :async_worlds

  def migrate do
    load_app()

    for repo <- Application.fetch_env!(@app, :ecto_repos) do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    :ok
  end

  @doc "Idempotent campaign setup from trusted operator environment variables."
  def setup do
    setup(%{
      discord_guild_id: System.get_env("DISCORD_GUILD_ID"),
      dm_user_id: System.get_env("DISCORD_DM_USER_ID"),
      public_channel_id: System.get_env("DISCORD_PUBLIC_CHANNEL_ID")
    })
  end

  def setup(attrs) do
    load_app()

    changeset =
      AsyncWorlds.Campaigns.Campaign.setup_changeset(%AsyncWorlds.Campaigns.Campaign{}, attrs)

    unless changeset.valid?,
      do: raise("Invalid campaign setup: guild, DM and public channel IDs are required")

    {:ok, result, _} =
      Ecto.Migrator.with_repo(AsyncWorlds.Repo, fn _ ->
        AsyncWorlds.Campaigns.setup_campaign(attrs)
      end)

    case result do
      {:ok, campaign} -> campaign
      {:error, _} -> raise "Campaign setup failed"
    end
  end

  defp load_app do
    Application.ensure_loaded(@app)
  end
end
