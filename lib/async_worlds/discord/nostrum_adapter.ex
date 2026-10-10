defmodule AsyncWorlds.Discord.NostrumAdapter do
  @moduledoc "Nostrum 0.10 transport implementation; every interaction response is private."
  @behaviour AsyncWorlds.Discord.Adapter

  alias Nostrum.Api.{ApplicationCommand, Interaction, Message, User}

  @impl true
  def defer(interaction) do
    Interaction.create_response(
      integer_id(interaction.id),
      interaction.token,
      deferred_response()
    )
    |> normalize_acknowledgment()
  end

  @doc false
  def normalize_acknowledgment({:ok}), do: :ok
  def normalize_acknowledgment({:error, _} = error), do: error

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

  @impl true
  def send_public(channel_id, payload) do
    send_request(fn -> Message.create(integer_id(channel_id), payload) end, :message)
  end

  @impl true
  def send_private(user_id, payload) do
    case send_request(fn -> User.create_dm(integer_id(user_id)) end, :channel) do
      {:ok, channel} -> send_public(to_string(channel.id), payload)
      {:error, _} = error -> error
    end
  end

  defp send_request(fun, stage) do
    classify_send(fun.(), stage)
  rescue
    _ -> unknown_send(stage)
  catch
    _, _ -> unknown_send(stage)
  end

  # Only safe classifications escape this boundary, never Discord error bodies.
  @doc false
  def classify_send({:ok, %{id: id, channel_id: channel}}, :message),
    do: {:ok, %{message_id: to_string(id), channel_id: to_string(channel)}}

  def classify_send({:ok, channel}, :channel), do: {:ok, channel}
  def classify_send({:error, %{status_code: 429}}, _), do: {:error, {:retryable, :rate_limited}}
  def classify_send({:error, {:retry_after, _}}, _), do: {:error, {:retryable, :rate_limited}}
  def classify_send({:error, %{status_code: 403}}, _), do: {:error, {:permanent, :forbidden}}
  def classify_send({:error, %{status_code: 401}}, _), do: {:error, {:permanent, :unauthorized}}
  def classify_send({:error, %{status_code: 404}}, _), do: {:error, {:permanent, :not_found}}

  def classify_send({:error, %{status_code: code}}, _) when code in 400..499,
    do: {:error, {:permanent, :invalid_request}}

  def classify_send(_, stage), do: unknown_send(stage)

  defp unknown_send(:channel), do: {:error, {:retryable, :channel_unavailable}}
  defp unknown_send(:message), do: {:error, {:ambiguous, :unknown_result}}

  @doc false
  def deferred_response, do: %{type: 5, data: %{flags: 64}}

  @doc false
  def response_data(content), do: %{content: content, allowed_mentions: %{parse: []}}

  defp integer_id(id) when is_integer(id), do: id
  defp integer_id(id) when is_binary(id), do: String.to_integer(id)
end
