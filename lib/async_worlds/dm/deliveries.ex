defmodule AsyncWorlds.DM.Deliveries do
  @moduledoc "Actor-aware DM delivery inspection/retries. Worker/outbox primitives are not exposed."
  alias AsyncWorlds.{Deliveries, DMAccess}

  def list_deliveries(scope),
    do: DMAccess.run(scope, fn c, _ -> {:ok, Deliveries.list_deliveries(c.id)} end)

  def recent_deliveries(scope, limit \\ 50),
    do: DMAccess.run(scope, fn c, _ -> {:ok, Deliveries.recent_deliveries(c.id, limit)} end)

  def search_deliveries(scope, filters \\ %{}, limit \\ 50),
    do: DMAccess.run(scope, fn c, _ -> Deliveries.search_deliveries(c.id, filters, limit) end)

  def fetch_delivery(scope, id),
    do: DMAccess.run(scope, fn c, _ -> Deliveries.fetch_delivery(c.id, id) end)

  def retry_delivery(scope, id, generation, opts \\ []),
    do: DMAccess.run(scope, fn c, _ -> Deliveries.retry_delivery(c.id, id, generation, opts) end)
end
