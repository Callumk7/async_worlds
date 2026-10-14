defmodule AsyncWorlds.Ticks.Opening do
  @moduledoc "Authorized opening preparation and atomic, stale-checked briefing delivery. See docs/tick-opening.md."
  import Ecto.Query
  alias AsyncWorlds.{DMAccess, Quests, Repo, Ticks}
  alias AsyncWorlds.Characters.Character
  alias AsyncWorlds.Quests.{Progression, Revision, Unlock}
  alias AsyncWorlds.Clocks.{Clock, Audit}
  alias AsyncWorlds.Ticks.OpeningOutput
  alias AsyncWorldsWeb.Endpoint

  @salt "tick-opening-v1"
  @max_age 3600

  def prepare(scope, attrs \\ %{}) do
    DMAccess.run(scope, fn campaign, actor ->
      with {:ok, narration} <- narration(attrs),
           :ok <- ready(campaign),
           {:ok, activities} <- activities(campaign, actor) do
        version = input_version(campaign)
        token = Phoenix.Token.sign(Endpoint, @salt, {campaign.id, actor, version, narration})
        {:ok, preparation(campaign, activities, narration, version, token)}
      end
    end)
  end

  def preview(scope, token) do
    DMAccess.run(scope, fn campaign, actor -> validate(campaign, actor, token) end)
  end

  @doc "Atomically opens with the inspected public briefing and existing private prompts."
  def open(scope, token) do
    DMAccess.run(scope, fn campaign, actor ->
      with {:ok, preparation} <- validate(campaign, actor, token) do
        Ticks.open_tick(campaign.id, preparation)
      end
    end)
  end

  @doc false
  # Trusted default-open path; caller holds the campaign lock. No optional setup
  # or network is required by Discord/HTTP opening.
  def capture(campaign) do
    with :ok <- ready(campaign),
         {:ok, activities} <- activities(campaign, campaign.dm_user_id) do
      {:ok, preparation(campaign, activities, "", input_version(campaign), nil)}
    end
  end

  defp validate(campaign, actor, token) when is_binary(token) do
    with {:ok, {id, ^actor, version, text}} when id == campaign.id <-
           Phoenix.Token.verify(Endpoint, @salt, token, max_age: @max_age),
         {:ok, text} <- narration(%{"narration" => text}),
         :ok <- ready(campaign),
         :ok <- current_version(campaign, version),
         {:ok, activities} <- activities(campaign, actor) do
      {:ok, preparation(campaign, activities, text, version, token)}
    else
      {:error, reason} when reason in [:active_tick, :tick_locked, :stale_preparation] ->
        {:error, reason}

      _ ->
        {:error, :invalid_preparation}
    end
  end

  defp validate(_, _, _), do: {:error, :invalid_preparation}

  defp current_version(campaign, version) do
    if input_version(campaign) == version, do: :ok, else: {:error, :stale_preparation}
  end

  defp ready(%{clock_mutations_locked: true}), do: {:error, :tick_locked}

  defp ready(campaign) do
    if Ticks.active_tick(campaign.id), do: {:error, :active_tick}, else: :ok
  end

  defp narration(attrs) when is_map(attrs) and not is_struct(attrs) do
    if Map.keys(attrs) -- ["narration"] == [] do
      validate_narration(Map.get(attrs, "narration", ""))
    else
      {:error, :invalid_opening}
    end
  end

  defp narration(_), do: {:error, :invalid_opening}

  defp validate_narration(text) when is_binary(text) do
    if safe_text?(text), do: {:ok, String.trim(text)}, else: {:error, :invalid_opening}
  end

  defp validate_narration(_), do: {:error, :invalid_opening}

  defp safe_text?(text) do
    byte_size(text) <= 8000 and String.valid?(text) and
      not Regex.match?(~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/u, text)
  end

  defp activities(campaign, actor) do
    owners =
      Repo.all(from c in Character, where: c.campaign_id == ^campaign.id)
      |> Map.new(&{&1.id, &1.discord_user_id})

    with {:ok, rows} <- Quests.public_activities(campaign, actor) do
      {:ok, Enum.map(rows, &Map.put(&1, :dm_controlled, is_nil(owners[&1.character_id])))}
    end
  end

  defp preparation(campaign, activities, narration, version, token) do
    number = campaign.current_tick_number + 1

    %{
      campaign_id: campaign.id,
      tick_number: number,
      public_channel_id: campaign.public_channel_id,
      narration: narration,
      version: version,
      token: token,
      messages: OpeningOutput.render(number, campaign.public_channel_id, activities, narration)
    }
  end

  # The digest never leaves private input data in the preview/token. Ordered raw
  # records include character generations and progression versions (ABA safety),
  # clock audit identities, ownership, availability and campaign configuration.
  # All supported writers serialize on DMAccess's campaign lock.
  defp input_version(campaign) do
    inputs =
      Enum.map([Character, Progression, Revision, Unlock, Clock, Audit], fn schema ->
        Repo.all(from r in schema, where: r.campaign_id == ^campaign.id, order_by: r.id)
      end)

    {OpeningOutput.version(), campaign, inputs}
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
  end
end
