defmodule AsyncWorlds.Discord.Dispatcher do
  @moduledoc """
  Handles trusted gateway interactions through an injectable transport.

  Ordinary interactions defer privately before database work, then check application, configured
  guild and verified guild-member identity. Unknown commands and denied requests
  receive private replies. No domain action runs after a failed acknowledgment.
  """
  require Logger

  alias AsyncWorlds.Campaigns

  alias AsyncWorlds.Discord.{
    Commands,
    DebugInteractions,
    JournalInteractions,
    ModalDeadline,
    QuestInteractions,
    Snowflake
  }

  def handle(interaction, opts \\ Application.fetch_env!(:async_worlds, :discord))

  def handle(%{type: 5} = interaction, opts) do
    if JournalInteractions.modal_submit?(interaction),
      do: handle_supported(interaction, opts),
      else: :ignored
  end

  def handle(%{type: type} = interaction, opts) when type in [2, 3],
    do: handle_supported(interaction, opts)

  def handle(_, _), do: :ignored

  defp handle_supported(interaction, opts) do
    adapter = Keyword.fetch!(opts, :adapter)

    with {:ok, id} <- Snowflake.cast(Map.get(interaction, :id)),
         {:ok, application_id} <- Snowflake.cast(Map.get(interaction, :application_id)),
         {:ok, configured_app} <- Snowflake.cast(opts[:application_id]),
         true <- application_id == configured_app,
         token when is_binary(token) and byte_size(token) > 0 <- Map.get(interaction, :token) do
      envelope = %{id: id, application_id: application_id, token: token}

      if JournalInteractions.modal_open?(interaction) do
        open_journal_modal(interaction, envelope, opts)
      else
        case safely(:acknowledgment, fn -> adapter.defer(envelope) end) do
          :ok -> dispatch(interaction, envelope, opts)
          _ -> {:error, :acknowledgment_failed}
        end
      end
    else
      _ -> :ignored
    end
  end

  # Opening a modal is itself the initial acknowledgment. Never defer first,
  # and never send another acknowledgment after an ambiguous modal response.
  defp open_journal_modal(interaction, envelope, opts) do
    result =
      safely(:command, fn ->
        ModalDeadline.run(Keyword.get(opts, :modal_deadline, ModalDeadline.deadline()), fn ->
          with {:ok, campaign, actor} <- authorize(interaction, :player, opts),
               {:ok, context} <- command_context(:player, campaign, actor) do
            JournalInteractions.open(interaction.data.custom_id, context)
          end
        end)
      end)

    adapter = Keyword.fetch!(opts, :adapter)

    case result do
      {:ok, modal} ->
        case safely(:acknowledgment, fn -> adapter.open_modal(envelope, modal) end) do
          :ok -> {:ok, :modal_opened}
          _ -> {:error, :acknowledgment_failed}
        end

      error ->
        case safely(:acknowledgment, fn -> adapter.defer(envelope) end) do
          :ok -> respond(error, envelope, opts, true)
          _ -> {:error, :acknowledgment_failed}
        end
    end
  end

  defp dispatch(interaction, envelope, opts) do
    result =
      safely(:command, fn ->
        with {:ok, command, permission} <- route(interaction),
             {:ok, campaign, user_id} <- authorize(interaction, permission, opts),
             {:ok, context} <- command_context(permission, campaign, user_id),
             true <- permission != :dm or context.role == :dm do
          handler = Keyword.get(opts, :handler, Commands)
          context = Map.put(context, :interaction_id, envelope.id)
          handler.execute(command, context) |> testing_banner(context, permission)
        else
          false -> {:error, :unauthorized}
          error -> error
        end
      end)

    journal? =
      JournalInteractions.modal_submit?(interaction) or
        JournalInteractions.journal_control?(interaction) or
        match?(%{data: %{name: "journal"}}, interaction)

    respond(result, envelope, opts, journal?)
  end

  defp respond(result, envelope, opts, journal?) do
    content =
      case result do
        {:ok, content} when is_binary(content) and byte_size(content) > 0 ->
          content

        {:ok, %{content: content, components: components}} when is_binary(content) ->
          %{content: content, components: components}

        {:error, :stale_component} ->
          if journal?,
            do:
              "This journal control has expired or changed. Refresh with /journal list, /journal open or /journal new.",
            else:
              "This control is no longer available. Use /quest or /submission to refresh your choices."

        {:error, :modal_deadline} ->
          "The journal form could not be prepared in time. Run /journal new and try again."

        {:error, :invalid_journal_input} ->
          "Use a nonblank title (up to 100 characters) and entry (up to 4,000 characters). Nothing was saved; run /journal new to try again."

        {:error, :unknown_command} ->
          "This command is not supported."

        {:error, reason} when reason in [:unauthorized, :not_found, :invalid_id] ->
          if journal?,
            do: "This journal entry or operation is unavailable.",
            else: "This command is not available to you in this server."

        _ ->
          "The command could not be completed. Please check its status before retrying."
      end

    adapter = Keyword.fetch!(opts, :adapter)

    [first | rest] = response_chunks(content)

    response =
      with :ok <- safely(:response, fn -> adapter.edit_response(envelope, first) end) do
        Enum.reduce_while(rest, :ok, fn chunk, :ok ->
          case safely(:response, fn -> adapter.followup_response(envelope, chunk) end) do
            :ok -> {:cont, :ok}
            _ -> {:halt, {:error, :response_failed}}
          end
        end)
      end

    case response do
      :ok -> result
      _ -> {:error, :response_failed}
    end
  end

  defp route(%{type: 5, data: %{custom_id: id, components: components}}) do
    {:ok, {:journal_submit, id, components}, :player}
  end

  defp route(%{type: 3, data: %{custom_id: "db:" <> _} = data}),
    do: DebugInteractions.component_route(data)

  defp route(%{type: 3, data: %{custom_id: "j1:" <> _} = data}),
    do: JournalInteractions.component_route(data)

  defp route(%{type: 3, data: data}), do: QuestInteractions.route(data)
  defp route(interaction), do: Commands.route(Map.get(interaction, :data))

  defp response_chunks(%{content: content, components: components}) do
    chunks = AsyncWorlds.Discord.Content.chunks(content)
    last = length(chunks) - 1

    Enum.with_index(chunks, fn chunk, index ->
      %{content: chunk, components: if(index == last, do: components, else: [])}
    end)
  end

  defp response_chunks(content), do: AsyncWorlds.Discord.Content.chunks(content)

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

  defp lookup(permission, guild_id, user_id) when permission in [:dm, :debug],
    do: Campaigns.authorize_dm(guild_id, user_id)

  defp lookup(:player, guild_id, _user_id), do: Campaigns.fetch_campaign_by_guild(guild_id)

  # Debug is the escape hatch even if a selected character was deleted.
  defp command_context(:debug, campaign, actor),
    do: {:ok, %{campaign: campaign, user_id: actor, access: actor, role: :dm}}

  defp command_context(_, campaign, actor), do: AsyncWorlds.PlayerAccess.context(campaign, actor)

  defp testing_banner({:ok, response}, %{debug_character: name}, :player) do
    banner = "Testing as #{name} · player · changes are real\n"

    case response do
      content when is_binary(content) -> {:ok, banner <> content}
      %{content: content} -> {:ok, %{response | content: banner <> content}}
    end
  end

  defp testing_banner(result, _, _), do: result

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
    exception ->
      log_exception(stage, exception.__struct__, __STACKTRACE__)
      {:error, :failed}
  catch
    _, _ ->
      log_failure(stage)
      {:error, :failed}
  end

  defp log_exception(stage, kind, stacktrace) do
    # Only module/function/arity, never arguments or exception messages.
    location =
      case stacktrace do
        [{module, function, arity, _} | _] when is_integer(arity) ->
          "#{inspect(module)}.#{function}/#{arity}"

        _ ->
          "unavailable"
      end

    Logger.warning(
      "Discord operation failed (#{inspect(kind)} at #{location})",
      discord_stage: stage
    )
  end

  defp log_failure(stage) do
    # Never inspect exceptions, response bodies, interaction payloads or URLs:
    # all can contain tokens or player-private content.
    Logger.warning("Discord operation failed", discord_stage: stage)
  end
end
