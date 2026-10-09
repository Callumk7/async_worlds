defmodule AsyncWorlds.Discord.Dispatcher do
  @moduledoc """
  Handles trusted gateway interactions through an injectable transport.

  Defers privately before database work, then checks application, configured
  guild and verified guild-member identity. Unknown commands and denied requests
  receive private replies. No domain action runs after a failed acknowledgment.
  """
  require Logger

  alias AsyncWorlds.Campaigns
  alias AsyncWorlds.Discord.{Commands, Snowflake}

  def handle(interaction, opts \\ Application.fetch_env!(:async_worlds, :discord))

  def handle(%{type: 2} = interaction, opts) do
    adapter = Keyword.fetch!(opts, :adapter)

    with {:ok, id} <- Snowflake.cast(Map.get(interaction, :id)),
         {:ok, application_id} <- Snowflake.cast(Map.get(interaction, :application_id)),
         {:ok, configured_app} <- Snowflake.cast(opts[:application_id]),
         true <- application_id == configured_app,
         token when is_binary(token) and byte_size(token) > 0 <- Map.get(interaction, :token) do
      envelope = %{id: id, application_id: application_id, token: token}

      case safely(:acknowledgment, fn -> adapter.defer(envelope) end) do
        :ok -> dispatch(interaction, envelope, opts)
        _ -> {:error, :acknowledgment_failed}
      end
    else
      _ -> :ignored
    end
  end

  def handle(_, _), do: :ignored

  defp dispatch(interaction, envelope, opts) do
    result =
      safely(:command, fn ->
        with {:ok, command, permission} <- Commands.route(Map.get(interaction, :data)),
             {:ok, campaign, user_id} <- authorize(interaction, permission, opts) do
          handler = Keyword.get(opts, :handler, Commands)

          handler.execute(command, %{
            campaign: campaign,
            user_id: user_id,
            interaction_id: envelope.id
          })
        end
      end)

    content =
      case result do
        {:ok, content} when is_binary(content) and byte_size(content) <= 2000 ->
          content

        {:error, :unknown_command} ->
          "This command is not supported."

        {:error, reason} when reason in [:unauthorized, :not_found, :invalid_id] ->
          "This command is not available to you in this server."

        _ ->
          "The command could not be completed. Please check its status before retrying."
      end

    adapter = Keyword.fetch!(opts, :adapter)

    case safely(:response, fn -> adapter.edit_response(envelope, content) end) do
      :ok -> result
      _ -> {:error, :response_failed}
    end
  end

  defp authorize(interaction, permission, opts) do
    # A guild interaction must carry a guild member. Never substitute a
    # top-level user or command option for the gateway-authenticated member.
    user = get_in_member(interaction)

    with {:ok, guild_id} <- Snowflake.cast(Map.get(interaction, :guild_id)),
         {:ok, configured_guild} <- Snowflake.cast(opts[:guild_id]),
         true <- guild_id == configured_guild,
         {:ok, user_id} <- Snowflake.cast(user),
         {:ok, campaign} <- lookup(permission, guild_id, user_id) do
      {:ok, campaign, user_id}
    else
      _ -> {:error, :unauthorized}
    end
  end

  defp get_in_member(%{member: %{user_id: id}}), do: id
  defp get_in_member(_), do: nil

  defp lookup(:dm, guild_id, user_id), do: Campaigns.authorize_dm(guild_id, user_id)
  defp lookup(:player, guild_id, _user_id), do: Campaigns.fetch_campaign_by_guild(guild_id)

  @doc false
  def safely(stage, fun) do
    case fun.() do
      {:error, _} = error ->
        if stage != :command, do: log_failure(stage)
        error

      result ->
        result
    end
  rescue
    _ ->
      log_failure(stage)
      {:error, :failed}
  catch
    _, _ ->
      log_failure(stage)
      {:error, :failed}
  end

  defp log_failure(stage) do
    # Never inspect exceptions, response bodies, interaction payloads or URLs:
    # all can contain tokens or player-private content.
    Logger.warning("Discord operation failed", discord_stage: stage)
  end
end
