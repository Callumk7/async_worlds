defmodule AsyncWorlds.DM.Tensions do
  @moduledoc "Freshly authorized shared DM operations. Tensions are private; status is publication-owned."
  alias AsyncWorlds.{Clocks, DMAccess, Tensions}

  def list_tensions(scope),
    do: DMAccess.run(scope, fn c, _ -> {:ok, Tensions.list_tensions(c.id)} end)

  def get_tension(scope, id),
    do: DMAccess.run(scope, fn c, _ -> Tensions.get_tension(c.id, id) end)

  def list_clocks(scope, id),
    do: DMAccess.run(scope, fn c, _ -> Tensions.list_clocks(c.id, id) end)

  def create_tension(scope, attrs, origin \\ :web),
    do: manage(scope, origin, fn id, source -> Tensions.create_tension(id, attrs, source) end)

  def edit_tension(scope, id, attrs, expected, origin \\ :web),
    do:
      manage(scope, origin, fn campaign_id, source ->
        Tensions.edit_tension(campaign_id, id, attrs, source, expected)
      end)

  def create_clock(scope, tension_id, attrs, origin \\ :web),
    do:
      manage(scope, origin, fn id, source ->
        Tensions.create_clock(id, tension_id, attrs, source)
      end)

  def associate_clock(scope, clock_id, tension_id, expected, origin \\ :web),
    do:
      manage(scope, origin, fn id, source ->
        Clocks.associate_clock(id, clock_id, tension_id, source, expected)
      end)

  defp manage(scope, origin, fun) do
    DMAccess.run(scope, fn campaign, actor ->
      with {:ok, source} <- DMAccess.source(actor, origin), do: fun.(campaign.id, source)
    end)
  end
end
