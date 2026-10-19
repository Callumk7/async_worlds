defmodule AsyncWorlds.Tensions do
  @moduledoc """
  Trusted campaign-scoped Tension storage. All Tensions and their prose are
  private DM-only; no player projection exists. Use DM.Tensions at interfaces.
  Status is read-only here: tick publication establishes resolutions.
  New frozen ticks treat associated clock endpoints as adjudication prompts;
  standalone clocks and older snapshots retain legacy completion rules.
  """
  import Ecto.Query
  alias AsyncWorlds.{Clocks, Repo, ScopedID}
  alias AsyncWorlds.Tensions.Tension

  def list_tensions(campaign_id),
    do:
      Repo.all(
        from t in Tension, where: t.campaign_id == ^campaign_id, order_by: [t.status, t.id]
      )

  def get_tension(campaign_id, id) do
    with {:ok, id} <- ScopedID.cast(id) do
      case Repo.get_by(Tension, campaign_id: campaign_id, id: id) do
        nil -> {:error, :not_found}
        tension -> {:ok, tension}
      end
    end
  end

  def create_tension(campaign_id, attrs, source) do
    Clocks.manage(campaign_id, source, fn ->
      %Tension{campaign_id: campaign_id}
      |> Tension.changeset(attrs)
      |> Repo.insert()
      |> persist!()
    end)
  end

  def edit_tension(campaign_id, id, attrs, source, expected) do
    Clocks.manage(campaign_id, source, fn ->
      tension = fetch!(campaign_id, id)
      if tension != expected, do: Repo.rollback(:stale_tension)

      tension
      |> Tension.changeset(attrs)
      |> Ecto.Changeset.put_change(:revision, tension.revision + 1)
      |> Repo.update()
      |> persist!()
    end)
  end

  def list_clocks(campaign_id, id) do
    with {:ok, tension} <- get_tension(campaign_id, id) do
      {:ok,
       Repo.all(
         from c in AsyncWorlds.Clocks.Clock,
           where: c.campaign_id == ^campaign_id and c.tension_id == ^tension.id,
           order_by: c.id
       )}
    end
  end

  def create_clock(campaign_id, id, attrs, source) do
    Clocks.manage(campaign_id, source, fn ->
      tension = fetch!(campaign_id, id)
      clock = persist!(Clocks.create_clock(campaign_id, private_clock_defaults(attrs), source))
      persist!(Clocks.associate_clock(campaign_id, clock.id, tension.id, source, clock))
    end)
  end

  defp private_clock_defaults(attrs) do
    key = if Enum.any?(Map.keys(attrs), &is_binary/1), do: "visibility", else: :visibility
    Map.put_new(attrs, key, :hidden)
  end

  defp fetch!(campaign_id, id) do
    case get_tension(campaign_id, id) do
      {:ok, tension} -> tension
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp persist!({:ok, value}), do: value
  defp persist!({:error, changeset}), do: Repo.rollback(changeset)
end
