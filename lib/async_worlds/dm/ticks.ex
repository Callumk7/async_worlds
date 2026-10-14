defmodule AsyncWorlds.DM.Ticks do
  @moduledoc "Actor-aware DM tick operations. Trusted engine primitives remain in AsyncWorlds.Ticks."
  alias AsyncWorlds.{DMAccess, Ticks}

  def active_tick(scope),
    do: DMAccess.run(scope, fn c, _ -> {:ok, Ticks.active_tick(c.id)} end)

  def latest_published_tick(scope),
    do: DMAccess.run(scope, fn c, _ -> {:ok, Ticks.latest_published_tick(c.id)} end)

  def status(scope),
    do:
      DMAccess.run(scope, fn c, _ ->
        {:ok, Ticks.active_tick(c.id) || Ticks.latest_published_tick(c.id)}
      end)

  def fetch_tick(scope, id),
    do: DMAccess.run(scope, fn c, _ -> Ticks.fetch_tick(c.id, id) end)

  def fetch_tick_by_number(scope, number),
    do: DMAccess.run(scope, fn c, _ -> Ticks.fetch_tick_by_number(c.id, number) end)

  def fetch_ticks(scope, ids),
    do: DMAccess.run(scope, fn c, _ -> {:ok, Ticks.fetch_ticks(c.id, ids)} end)

  def fetch_snapshot(scope, id),
    do: DMAccess.run(scope, fn c, _ -> Ticks.fetch_snapshot(c.id, id) end)

  def fetch_draft(scope, id),
    do: DMAccess.run(scope, fn c, _ -> Ticks.fetch_draft(c.id, id) end)

  def resolution_jobs(scope, id),
    do: DMAccess.run(scope, fn c, _ -> Ticks.resolution_jobs(c.id, id) end)

  def list_review_edits(scope, id),
    do: DMAccess.run(scope, fn c, _ -> Ticks.list_review_edits(c.id, id) end)

  def fetch_publication(scope, id),
    do: DMAccess.run(scope, fn c, _ -> Ticks.fetch_publication(c.id, id) end)

  def open_tick(scope),
    do: DMAccess.run(scope, fn c, _ -> Ticks.open_tick(c.id) end)

  def close_tick(scope, id),
    do: DMAccess.run(scope, fn c, _ -> Ticks.close_tick(c.id, id) end)

  @doc "Select and close the active tick under the same authorization lock."
  def close_active_tick(scope) do
    DMAccess.run(scope, fn c, _ ->
      case Ticks.active_tick(c.id) do
        nil -> {:error, :no_tick}
        tick -> Ticks.close_tick(c.id, tick.id)
      end
    end)
  end

  def preview_draft(scope, id, draft_id),
    do: DMAccess.run(scope, fn c, _ -> Ticks.preview_draft(c.id, id, draft_id) end)

  def edit_draft(scope, id, draft_id, operation, reason),
    do:
      DMAccess.run(scope, fn c, actor ->
        Ticks.edit_draft(c.id, id, draft_id, operation, actor, reason)
      end)

  def publish_tick(scope, id, draft_id),
    do: DMAccess.run(scope, fn c, _ -> Ticks.publish_tick(c.id, id, draft_id) end)

  def remind(scope, request_id),
    do:
      DMAccess.run(scope, fn c, actor ->
        AsyncWorlds.Ticks.PrivateNotifications.remind(c.discord_guild_id, actor, request_id)
      end)
end
