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

  @callback send_public(String.t(), map()) :: send_result()
  @callback send_private(String.t(), map()) :: send_result()

  @callback defer(map()) :: :ok | {:error, term()}
  @callback edit_response(map(), String.t()) :: :ok | {:error, term()}
  @callback register_commands(String.t(), String.t(), [map()]) ::
              {:ok, [map()]} | {:error, term()}
end
