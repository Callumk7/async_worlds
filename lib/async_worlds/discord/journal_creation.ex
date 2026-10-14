defmodule AsyncWorlds.Discord.JournalCreation do
  @moduledoc "Discord's expiring modal receipts. Draft content and interaction tokens are never persisted here."
  alias AsyncWorlds.{Journals, Repo}
  alias AsyncWorlds.Discord.Snowflake
  alias AsyncWorlds.Journals.CreationReceipt

  def begin_creation(context, request_id, visibility \\ "private") do
    with {:ok, request_id} <- Snowflake.cast(request_id),
         {:ok, visibility} <- visibility(visibility) do
      Journals.with_player(context, fn campaign, character, binding ->
        case Repo.get_by(CreationReceipt, campaign_id: campaign.id, request_id: request_id) do
          nil ->
            %CreationReceipt{
              campaign_id: campaign.id,
              character_id: character.id,
              request_id: request_id,
              actor_id: binding["actor"],
              binding: binding,
              origin: if(is_map(context.access), do: :dm_persona, else: :player),
              visibility: visibility,
              expires_at: DateTime.add(DateTime.utc_now(), 900, :second)
            }
            |> Repo.insert!()
            |> Journals.creation_outcome()

          receipt ->
            unless receipt.binding == binding and receipt.visibility == visibility,
              do: Repo.rollback(:stale_component)

            Journals.creation_outcome(receipt)
        end
      end)
    end
  end

  def open_creation(context, receipt_id) do
    Journals.with_player(context, fn campaign, _character, binding ->
      receipt = receipt!(campaign, binding, receipt_id)
      pending!(receipt)
      Journals.creation_outcome(receipt)
    end)
  end

  def submit(context, receipt_id, attrs) do
    Journals.with_player(context, fn campaign, _character, binding ->
      receipt = receipt!(campaign, binding, receipt_id)
      unless receipt.state in [:completed, :deleted], do: pending!(receipt)
      Journals.persist_creation(receipt, attrs)
    end)
  end

  def cancel_creation(context, receipt_id) do
    Journals.with_player(context, fn campaign, _character, binding ->
      receipt = receipt!(campaign, binding, receipt_id)
      pending!(receipt)

      receipt
      |> Ecto.Changeset.change(state: :canceled)
      |> Repo.update!()
      |> Journals.creation_outcome()
    end)
  end

  defp receipt!(campaign, binding, receipt_id) do
    with {:ok, id} <- Ecto.UUID.cast(receipt_id),
         %CreationReceipt{} = receipt <-
           Repo.get_by(CreationReceipt, campaign_id: campaign.id, id: id),
         true <- receipt.binding == binding do
      receipt
    else
      _ -> Repo.rollback(:stale_component)
    end
  end

  defp pending!(receipt) do
    unless receipt.state == :pending and
             DateTime.compare(receipt.expires_at, DateTime.utc_now()) == :gt,
           do: Repo.rollback(:stale_component)
  end

  defp visibility(value) when value in [:private, "private"], do: {:ok, :private}
  defp visibility(value) when value in [:public, "public"], do: {:ok, :public}
  defp visibility(_), do: {:error, :invalid_journal_input}
end
