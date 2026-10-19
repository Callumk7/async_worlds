defmodule AsyncWorlds.Ticks.History do
  @moduledoc "Freshly authorized, read-only browsing of saved publications, never live definitions."
  import Ecto.Query
  alias AsyncWorlds.{Campaigns, Repo}
  alias AsyncWorlds.Clocks.Audit
  alias AsyncWorlds.Deliveries.Delivery
  alias AsyncWorlds.Quests.Intervention
  alias AsyncWorlds.Ticks.{Draft, Publication, ReviewEdit, Tick}

  @page_size 20
  @sections ~w(events manual results clocks rolls consequences reviews interventions audits messages)

  def sections, do: @sections

  def list(guild_id, actor_id, page \\ 1) do
    with {:ok, campaign} <- Campaigns.authorize_dm(guild_id, actor_id),
         :ok <- valid_page(page) do
      query =
        from p in Publication,
          join: t in Tick,
          on: t.id == p.tick_id,
          where: t.campaign_id == ^campaign.id and t.status == :published,
          order_by: [desc: t.number, desc: t.id],
          select: %{
            id: t.id,
            number: t.number,
            published_at: p.inserted_at,
            events: fragment("COALESCE(?->'events', '[]'::jsonb)", p.payload)
          }

      {:ok, query_page(query, page)}
    end
  end

  def fetch(guild_id, actor_id, tick_id, pages \\ %{}) do
    with {:ok, campaign} <- Campaigns.authorize_dm(guild_id, actor_id),
         {:ok, tick_id} <- Ecto.Type.cast(:id, tick_id),
         true <-
           is_map(pages) and
             Enum.all?(pages, fn {key, page} -> key in @sections and valid_page(page) == :ok end) do
      query =
        from p in Publication,
          join: t in Tick,
          on: t.id == p.tick_id,
          join: d in Draft,
          on: d.id == p.draft_id and d.tick_id == t.id,
          where: t.campaign_id == ^campaign.id and t.id == ^tick_id and t.status == :published,
          select: {t, p, d.revision, d.input_revision}

      case Repo.one(query) do
        nil ->
          {:error, :not_found}

        {tick, publication, revision, input_revision} ->
          {:ok, detail(campaign.id, tick, publication, revision, input_revision, pages)}
      end
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :not_found}
    end
  end

  @doc "Private narrative-first Tension chronicle, using immutable publication context only."
  def tension(guild_id, actor_id, tension_id) do
    with {:ok, campaign} <- Campaigns.authorize_dm(guild_id, actor_id),
         {:ok, id} <- Ecto.Type.cast(:id, tension_id) do
      rows =
        Repo.all(
          from p in Publication,
            join: t in Tick,
            on: p.tick_id == t.id,
            where: t.campaign_id == ^campaign.id and t.status == :published,
            order_by: [desc: t.number],
            select: {t.id, t.number, p.payload}
        )

      {:ok,
       for(
         {tick_id, number, payload} <- rows,
         event <- payload["events"] || [],
         Enum.any?(event["changes"], fn c ->
           (c["entity"] == "tension" and published_id(payload, c["id"]) == id) or
             (c["entity"] == "clock" and published_id(payload, c["after"]["tension_id"]) == id)
         end),
         do: Map.merge(event, %{"tick_id" => tick_id, "tick_number" => number})
       )}
    end
  end

  defp published_id(payload, id), do: Map.get(payload["published_entity_ids"] || %{}, id, id)

  defp detail(campaign_id, tick, publication, revision, input_revision, pages) do
    payload = publication.payload
    page = fn key -> Map.get(pages, key, 1) end

    sources =
      Enum.map(payload["effects"] || [], & &1["source"]) ++
        Enum.map(payload["manual_changes"] || [], &("manual:tick:#{tick.id}:" <> &1["source"]))

    reviews =
      from e in ReviewEdit,
        where: e.tick_id == ^tick.id,
        order_by: e.id

    interventions =
      from i in Intervention,
        where: i.campaign_id == ^campaign_id and i.tick_id == ^tick.id,
        order_by: i.id

    audits =
      from a in Audit,
        where:
          a.campaign_id == ^campaign_id and a.operation == "publish" and a.source in ^sources,
        order_by: a.id

    %{
      tick: tick,
      publication: Map.take(publication, [:id, :draft_id, :inserted_at]),
      world_news: Enum.join(payload["world_news"] || [], "\n\n"),
      revision: revision,
      input_revision: input_revision,
      sections: %{
        "events" => list_page(payload["events"] || [], page.("events")),
        "manual" => list_page(payload["manual_changes"] || [], page.("manual")),
        "results" => list_page(player_results(payload), page.("results")),
        "clocks" => list_page(payload["clocks"] || [], page.("clocks")),
        "rolls" => list_page(payload["rolls"] || [], page.("rolls")),
        "consequences" => list_page(payload["log"] || [], page.("consequences")),
        "reviews" => query_page(reviews, page.("reviews")),
        "interventions" => query_page(interventions, page.("interventions")),
        "audits" => query_page(audits, page.("audits")),
        "messages" => message_page(campaign_id, tick.id, publication.outputs, page.("messages"))
      }
    }
  end

  defp player_results(payload) do
    characters = Map.new(payload["characters"] || [], &{&1["id"], &1})

    Enum.map(payload["private_results"] || [], fn result ->
      character = characters[result["character_id"]] || %{}

      name =
        character["name"] || "Character ##{result["character_id"]} (historical name not recorded)"

      Map.put(result, "historical_character", name)
    end)
  end

  defp message_page(campaign_id, tick_id, outputs, page) do
    messages =
      for audience <- ~w(public dm players),
          {recipient, messages} <-
            Enum.sort_by(
              Enum.group_by(outputs[audience] || [], & &1["recipient_id"]),
              &elem(&1, 0)
            ),
          {message, index} <- Enum.with_index(messages) do
        key =
          if message["character_id"] && message["delivery_audience"] do
            "tick:#{tick_id}:#{audience}:character:#{message["character_id"]}:#{message["delivery_audience"]}:#{recipient}:#{message["chunk_index"]}"
          else
            "tick:#{tick_id}:#{audience}:#{recipient}:#{index}"
          end

        %{
          audience: audience,
          route: message["delivery_audience"],
          character_id: message["character_id"],
          recipient: recipient,
          chunk: (message["chunk_index"] || index) + 1,
          content: message["content"],
          key: key
        }
      end

    result = list_page(messages, page)
    keys = Enum.map(result.items, & &1.key)

    deliveries =
      Repo.all(
        from d in Delivery,
          where: d.campaign_id == ^campaign_id and d.tick_id == ^tick_id and d.key in ^keys
      )

    by_key = Map.new(deliveries, &{&1.key, &1})
    %{result | items: Enum.map(result.items, &Map.put(&1, :delivery, by_key[&1.key]))}
  end

  defp valid_page(page) when is_integer(page) and page > 0 and page <= 100_000, do: :ok
  defp valid_page(_), do: {:error, :invalid_page}

  defp query_page(query, page) do
    query
    |> limit(^(@page_size + 1))
    |> offset(^((page - 1) * @page_size))
    |> Repo.all()
    |> page_result(page)
  end

  defp list_page(items, page),
    do: items |> Enum.slice((page - 1) * @page_size, @page_size + 1) |> page_result(page)

  defp page_result(items, page),
    do: %{items: Enum.take(items, @page_size), page: page, more?: length(items) > @page_size}
end
