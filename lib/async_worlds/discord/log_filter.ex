defmodule AsyncWorlds.Discord.LogFilter do
  @moduledoc """
  Redacts Nostrum rate-limiter logs, whose route/bucket URLs can contain
  interaction webhook tokens. Application logs never inspect transport errors.
  """

  def install do
    :logger.add_primary_filter(:async_worlds_discord_transport, {&__MODULE__.filter/2, nil})
  end

  @doc false
  def filter(%{meta: %{mfa: {Nostrum.Api.Ratelimiter, _, _}}} = event, _) do
    %{
      event
      | msg: {:string, ~c"Discord transport event (details redacted)"},
        meta: Map.take(event.meta, [:time, :gl, :pid, :mfa])
    }
  end

  def filter(_, _), do: :ignore
end
