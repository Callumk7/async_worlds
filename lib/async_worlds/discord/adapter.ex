defmodule AsyncWorlds.Discord.Adapter do
  @moduledoc """
  Discord transport boundary. Domain modules must not call Nostrum directly.

  A successful initial response is required before running a command. Transport
  failures are deliberately not retried here: an acknowledgment timeout may be
  ambiguous. Domain transitions must independently enforce atomic lifecycle and
  idempotency constraints, including for interactions with different IDs.
  """

  @type send_result ::
          {:ok, %{message_id: String.t(), channel_id: String.t()}}
          | {:error, {:retryable | :permanent | :ambiguous, atom()}}

  @callback create_public_thread(String.t(), map()) ::
              {:ok, %{thread_id: String.t()}} | {:error, {atom(), atom()}}
  @callback inspect_thread(String.t()) :: {:ok, map()} | {:error, term()}
  @optional_callbacks create_public_thread: 2, inspect_thread: 1

  @callback send_public(String.t(), map()) :: send_result()
  @callback send_private(String.t(), map()) :: send_result()

  @callback defer(map()) :: :ok | {:error, term()}
  @callback open_modal(map(), map()) :: :ok | {:error, term()}
  @type response :: String.t() | %{content: String.t(), components: [map()]}
  @callback edit_response(map(), response()) :: :ok | {:error, term()}
  @callback followup_response(map(), response()) :: :ok | {:error, term()}
  @callback register_commands(String.t(), String.t(), [map()]) ::
              {:ok, [map()]} | {:error, term()}
end
