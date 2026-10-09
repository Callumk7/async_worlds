defmodule AsyncWorlds.Discord.NostrumAdapter do
  @moduledoc "Nostrum 0.10 transport implementation; every interaction response is private."
  @behaviour AsyncWorlds.Discord.Adapter

  alias Nostrum.Api.{ApplicationCommand, Interaction}

  @impl true
  def defer(interaction) do
    Interaction.create_response(
      integer_id(interaction.id),
      interaction.token,
      deferred_response()
    )
  end

  @impl true
  def edit_response(interaction, content) do
    Interaction.edit_response(
      integer_id(interaction.application_id),
      interaction.token,
      response_data(content)
    )
    |> case do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  @impl true
  def register_commands(application_id, guild_id, commands) do
    ApplicationCommand.bulk_overwrite_guild_commands(
      integer_id(application_id),
      integer_id(guild_id),
      commands
    )
  end

  @doc false
  def deferred_response, do: %{type: 5, data: %{flags: 64}}

  @doc false
  def response_data(content), do: %{content: content, allowed_mentions: %{parse: []}}

  defp integer_id(id) when is_integer(id), do: id
  defp integer_id(id) when is_binary(id), do: String.to_integer(id)
end
