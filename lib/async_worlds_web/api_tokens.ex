defmodule AsyncWorldsWeb.ApiTokens do
  @moduledoc "Signed, scope-bound HTTP cursor and clock snapshot tokens. Tokens never replace domain authorization."
  alias AsyncWorldsWeb.Endpoint
  @cursor_salt "http-api-cursor-v1"
  @snapshot_salt "http-api-clock-v1"
  @max_age 86_400
  @max_id 9_223_372_036_854_775_807

  @doc "Resource must identify the collection AND its filters; pass only the domain's validated cursor."
  def cursor(_scope, _resource, nil), do: {:ok, nil}

  def cursor(scope, resource, cursor)
      when is_binary(resource) and byte_size(resource) in 1..200 do
    if valid_cursor?(cursor) do
      {:ok,
       Phoenix.Token.sign(Endpoint, @cursor_salt, %{
         scope: scope_binding(scope),
         resource: resource,
         cursor: cursor
       })}
    else
      {:error, :invalid_cursor}
    end
  end

  def cursor(_, _, _), do: {:error, :invalid_cursor}

  def decode_cursor(_scope, _resource, nil), do: {:ok, nil}

  def decode_cursor(scope, resource, token) do
    expected = scope_binding(scope)

    with {:ok, %{scope: ^expected, resource: ^resource, cursor: cursor}} <-
           verify(@cursor_salt, token),
         true <- valid_cursor?(cursor) do
      {:ok, cursor}
    else
      _ -> {:error, :invalid_cursor}
    end
  end

  @doc "Clock edits require this opaque snapshot token because their domain compares the full loaded clock."
  def clock_snapshot(scope, %AsyncWorlds.Clocks.Clock{} = clock) do
    Phoenix.Token.sign(Endpoint, @snapshot_salt, %{
      scope: scope_binding(scope),
      id: clock.id,
      digest: digest(clock)
    })
  end

  def verify_clock_snapshot(_scope, _clock, nil), do: {:error, :precondition_required}

  def verify_clock_snapshot(scope, %AsyncWorlds.Clocks.Clock{} = clock, token) do
    expected = %{scope: scope_binding(scope), id: clock.id, digest: digest(clock)}

    case verify(@snapshot_salt, token) do
      {:ok, ^expected} -> {:ok, clock}
      _ -> {:error, :stale_clock}
    end
  end

  defp verify(salt, token) when is_binary(token) and byte_size(token) in 1..4096,
    do: Phoenix.Token.verify(Endpoint, salt, token, max_age: @max_age)

  defp verify(_, _), do: {:error, :invalid}

  defp scope_binding(%{campaign: campaign, discord_user_id: actor}) do
    %{
      campaign: campaign.id,
      guild: campaign.discord_guild_id,
      dm: campaign.dm_user_id,
      channel: campaign.public_channel_id,
      actor: actor
    }
  end

  defp digest(record),
    do:
      :crypto.hash(:sha256, :erlang.term_to_binary(record, [:deterministic]))
      |> Base.encode16(case: :lower)

  defp valid_cursor?(%{direction: direction, anchor: anchor, ceiling: ceiling} = cursor)
       when direction in [:next, :previous] and is_integer(anchor) and anchor >= 0 and
              anchor <= @max_id and is_integer(ceiling) and ceiling <= @max_id and
              map_size(cursor) == 3,
       do:
         (direction == :next and anchor > 0 and ceiling >= anchor) or
           (direction == :previous and ceiling > anchor)

  defp valid_cursor?(_), do: false
end
