defmodule AsyncWorlds.DM.Clocks do
  @moduledoc "Actor-aware DM clock operations with identity-derived audit attribution."
  alias AsyncWorlds.{Clocks, DMAccess}

  def list_clocks(scope),
    do: DMAccess.run(scope, fn c, _ -> {:ok, Clocks.list_clocks(c.id)} end)

  def list_audits(scope),
    do: DMAccess.run(scope, fn c, _ -> {:ok, Clocks.list_audits(c.id)} end)

  def recent_audits(scope, limit \\ 8),
    do: DMAccess.run(scope, fn c, _ -> {:ok, Clocks.recent_audits(c.id, limit)} end)

  def create_clock(scope, attrs, origin \\ :http),
    do: manage(scope, origin, fn id, source -> Clocks.create_clock(id, attrs, source) end)

  def edit_clock(scope, id, attrs, origin \\ :http, expected_clock \\ nil),
    do:
      manage(scope, origin, fn campaign_id, source ->
        Clocks.edit_clock(campaign_id, id, attrs, source, expected_clock)
      end)

  def adjust_clock(scope, id, delta, origin \\ :http),
    do:
      manage(scope, origin, fn campaign_id, source ->
        Clocks.adjust_clock(campaign_id, id, delta, source)
      end)

  def reset_clock(scope, id, origin \\ :http),
    do:
      manage(scope, origin, fn campaign_id, source ->
        Clocks.reset_clock(campaign_id, id, source)
      end)

  def pair_clocks(scope, first, second, origin \\ :http),
    do:
      manage(scope, origin, fn campaign_id, source ->
        Clocks.pair_clocks(campaign_id, first, second, source)
      end)

  def unpair_clock(scope, id, origin \\ :http),
    do:
      manage(scope, origin, fn campaign_id, source ->
        Clocks.unpair_clock(campaign_id, id, source)
      end)

  defp manage(scope, origin, fun) do
    DMAccess.run(scope, fn campaign, actor ->
      with {:ok, source} <- DMAccess.source(actor, origin), do: fun.(campaign.id, source)
    end)
  end
end
