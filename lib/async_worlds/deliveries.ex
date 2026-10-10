defmodule AsyncWorlds.Deliveries do
  @moduledoc """
  Durable Discord outbox. Callers authorize the DM before reads/retries; enqueue
  is a trusted internal operation using approved, privacy-filtered content.

  Enqueue inside the publication transaction so records/jobs roll back together.
  A committed claim precedes network I/O. A crash or unknown transport outcome
  becomes ambiguous, never an automatic resend. Manual ambiguous retry requires
  explicit confirmation and may duplicate a message. Delivery never applies game
  state and never invokes publication.
  """
  import Ecto.Query
  import Ecto.Changeset
  alias AsyncWorlds.Repo
  alias AsyncWorlds.Campaigns.Campaign
  alias AsyncWorlds.Deliveries.Delivery
  alias AsyncWorlds.Ticks.Tick
  alias AsyncWorlds.Workers.DeliverDiscord

  def list_deliveries(campaign_id) do
    Repo.all(from d in Delivery, where: d.campaign_id == ^campaign_id, order_by: d.id)
  end

  def recent_deliveries(campaign_id, limit \\ 50) do
    Repo.all(
      from d in Delivery,
        where: d.campaign_id == ^campaign_id,
        order_by: [desc: d.id],
        limit: ^limit
    )
  end

  def fetch_delivery(campaign_id, id) do
    case Repo.get_by(Delivery, id: id, campaign_id: campaign_id) do
      nil -> {:error, :not_found}
      delivery -> {:ok, delivery}
    end
  end

  def enqueue(campaign_id, tick_id, attrs) do
    Repo.transaction(fn ->
      lock_campaign!(campaign_id)

      if not Repo.exists?(
           from t in Tick, where: t.id == ^tick_id and t.campaign_id == ^campaign_id
         ),
         do: Repo.rollback(:not_found)

      changeset = Delivery.changeset(%Delivery{campaign_id: campaign_id, tick_id: tick_id}, attrs)
      if not changeset.valid?, do: Repo.rollback(changeset)
      proposed = apply_changes(changeset)

      case Repo.get_by(Delivery, campaign_id: campaign_id, key: proposed.key) do
        nil ->
          delivery = Repo.insert!(changeset, log: false)
          insert_job!(delivery)
          delivery

        existing ->
          fields = [:tick_id, :key, :kind, :recipient_id, :content]

          if Map.take(existing, fields) != Map.take(proposed, fields),
            do: Repo.rollback(:delivery_conflict)

          existing
      end
    end)
  end

  @doc "Targeted retry with optimistic generation checks; never retry a sent record."
  def retry_delivery(campaign_id, id, expected_generation, opts \\ []) do
    Repo.transaction(fn ->
      lock_campaign!(campaign_id)
      delivery = lock_delivery!(id)
      if delivery.campaign_id != campaign_id, do: Repo.rollback(:not_found)
      if delivery.generation != expected_generation, do: Repo.rollback(:stale_delivery)

      case delivery.status do
        :failed ->
          :ok

        :ambiguous ->
          unless Keyword.get(opts, :confirm_ambiguous, false) == true,
            do: Repo.rollback(:confirmation_required)

        _ ->
          Repo.rollback(:not_retryable)
      end

      updated =
        update!(delivery,
          status: :pending,
          generation: delivery.generation + 1,
          error_class: nil,
          last_error: nil,
          started_at: nil
        )

      insert_job!(updated)
      updated
    end)
  end

  @doc false
  def claim(id, generation) do
    Repo.transaction(fn ->
      delivery = lock_delivery!(id)

      cond do
        delivery.generation != generation ->
          :skip

        delivery.status in [:sent, :ambiguous] ->
          :skip

        delivery.status == :failed and delivery.error_class != :retryable ->
          :skip

        delivery.status == :sending ->
          update!(delivery,
            status: :ambiguous,
            error_class: :ambiguous,
            last_error: "interrupted_send"
          )

          :skip

        true ->
          update!(delivery,
            status: :sending,
            attempts: delivery.attempts + 1,
            started_at: now(),
            error_class: nil,
            last_error: nil
          )
      end
    end)
  end

  @doc false
  def settle(%Delivery{} = claim, result) do
    Repo.transaction(fn ->
      delivery = lock_delivery!(claim.id)

      if delivery.generation != claim.generation or delivery.attempts != claim.attempts or
           delivery.status not in [:sending, :ambiguous],
         do: Repo.rollback(:stale_attempt)

      case result do
        {:ok, %{message_id: message_id, channel_id: channel_id}} ->
          update!(delivery,
            status: :sent,
            message_id: message_id,
            channel_id: channel_id,
            sent_at: now(),
            error_class: nil,
            last_error: nil
          )

        {:error, {class, reason}} when class in [:retryable, :permanent, :ambiguous] ->
          status = if class == :ambiguous, do: :ambiguous, else: :failed

          update!(delivery,
            status: status,
            error_class: class,
            last_error: Atom.to_string(reason)
          )
      end
    end)
  end

  defp insert_job!(delivery) do
    %{
      campaign_id: delivery.campaign_id,
      delivery_id: delivery.id,
      generation: delivery.generation
    }
    |> DeliverDiscord.new()
    |> Oban.insert()
    |> case do
      {:ok, job} -> job
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp lock_campaign!(id) do
    Repo.one(from c in Campaign, where: c.id == ^id, lock: "FOR UPDATE") ||
      Repo.rollback(:not_found)
  end

  defp lock_delivery!(id) do
    Repo.one(from d in Delivery, where: d.id == ^id, lock: "FOR UPDATE") ||
      Repo.rollback(:not_found)
  end

  defp update!(record, attrs), do: record |> change(attrs) |> Repo.update!()
  defp now, do: DateTime.utc_now()
end
