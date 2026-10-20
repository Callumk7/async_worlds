defmodule AsyncWorlds.Ticks.Chronicle do
  @moduledoc "One published Event chronicle. Audience and filters precede bounded database pagination."
  import Ecto.Query
  alias AsyncWorlds.{Campaigns, PlayerAccess, Repo}
  alias AsyncWorlds.Ticks.{EventReferences, Publication, Tick}
  @size 20

  def list(guild, actor, audience, filters \\ %{}) do
    authorize(guild, actor, audience, fn campaign ->
      with {:ok, f} <- filters(filters) do
        base = query(campaign.id, audience, f)

        through =
          f.through || base |> exclude(:select) |> select([t], max(t.number)) |> Repo.one() || 0

        rows =
          base
          |> where([t], t.number <= ^through)
          |> order_by([t, p, e], desc: t.number, desc: t.id, desc: fragment("?->>'id'", e.value))
          |> limit(^(@size + 1))
          |> offset(^((f.page - 1) * @size))
          |> Repo.all()

        %{
          items: Enum.map(Enum.take(rows, @size), &project(&1, audience)),
          page: f.page,
          more?: length(rows) > @size,
          through: through
        }
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  def fetch(guild, actor, audience, tick_id, key, filters \\ %{}) do
    authorize(guild, actor, audience, fn campaign ->
      with {:ok, f} <- filters(filters),
           {:ok, id} <- positive(tick_id),
           true <- is_binary(key) do
        base = query(campaign.id, audience, f)

        row =
          base
          |> where([t, p, e], t.id == ^id and fragment("?->>'id'", e.value) == ^key)
          |> Repo.one()

        if is_nil(row), do: Repo.rollback(:not_found)

        %{
          event: project(row, audience),
          earlier: neighbor(base, row, :earlier),
          later: neighbor(base, row, :later)
        }
      else
        _ -> Repo.rollback(:not_found)
      end
    end)
  end

  defp authorize(guild, actor, :dm, fun) do
    with {:ok, campaign} <- Campaigns.authorize_dm(guild, actor) do
      AsyncWorlds.DMAccess.run(%{campaign: campaign, discord_user_id: actor}, fn current, _ ->
        {:ok, fun.(current)}
      end)
    end
  end

  defp authorize(guild, actor, :player, fun),
    do: PlayerAccess.run(guild, actor, fn c, _ -> fun.(c) end)

  defp authorize(_, _, _, _), do: {:error, :unauthorized}

  defp filters(f) when is_map(f) do
    with true <- Enum.all?(Map.keys(f), &(&1 in ~w(page tick entity entity_id through))),
         {:ok, page} <- positive(Map.get(f, "page", 1)),
         true <- page <= div(9_223_372_036_854_775_807, @size),
         {:ok, tick} <- optional(f["tick"]),
         {:ok, through} <- optional(f["through"]),
         {:ok, id} <- optional(f["entity_id"]),
         true <-
           (is_nil(f["entity"]) and is_nil(id)) or
             (f["entity"] in ~w(tension location character faction) and not is_nil(id)) do
      {:ok, %{page: page, tick: tick, entity: f["entity"], entity_id: id, through: through}}
    else
      _ -> {:error, :invalid_filter}
    end
  end

  defp filters(_), do: {:error, :invalid_filter}
  defp positive(n) when is_integer(n) and n > 0 and n <= 9_223_372_036_854_775_807, do: {:ok, n}

  defp positive(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} when n > 0 and n <= 9_223_372_036_854_775_807 -> {:ok, n}
      _ -> :error
    end
  end

  defp positive(_), do: :error
  defp optional(nil), do: {:ok, nil}
  defp optional(n), do: positive(n)

  defp query(campaign, audience, f) do
    q =
      from t in Tick,
        join: p in Publication,
        on: p.tick_id == t.id,
        join:
          e in fragment("jsonb_array_elements(COALESCE(?->'events', '[]'::jsonb))", p.payload),
        on: true,
        where: t.campaign_id == ^campaign and t.status == :published,
        select: %{tick_id: t.id, number: t.number, event: e.value, payload: p.payload}

    q =
      if audience == :player,
        do: where(q, [t, p, e], fragment("?->>'audience'", e.value) == "public"),
        else: q

    q = if f.tick, do: where(q, [t], t.id == ^f.tick), else: q
    q = if f.through, do: where(q, [t], t.number <= ^f.through), else: q

    if f.entity do
      id = to_string(f.entity_id)

      where(
        q,
        [t, p, e],
        fragment(
          """
          EXISTS (SELECT 1 FROM jsonb_array_elements(COALESCE(?->'references', '[]'::jsonb)) r
            WHERE r->>'entity' = ? AND COALESCE(?->'published_entity_ids'->>(r->>'id'), r->>'id') = ?)
          OR (? = 'tension' AND EXISTS (
            SELECT 1 FROM jsonb_array_elements(COALESCE(?->'changes', '[]'::jsonb)) c
            WHERE COALESCE(?->'published_entity_ids'->>(CASE WHEN c->>'entity' = 'tension' THEN c->>'id' ELSE c->'after'->>'tension_id' END),
              CASE WHEN c->>'entity' = 'tension' THEN c->>'id' ELSE c->'after'->>'tension_id' END) = ?
              OR (c->>'entity' = 'clock' AND COALESCE(?->'published_entity_ids'->>(c->'before'->>'tension_id'), c->'before'->>'tension_id') = ?)))
          """,
          e.value,
          ^f.entity,
          p.payload,
          ^id,
          ^f.entity,
          e.value,
          p.payload,
          ^id,
          p.payload,
          ^id
        )
      )
    else
      q
    end
  end

  defp project(row, audience \\ :dm) do
    event =
      if audience == :player,
        do: Map.take(row.event, ~w(id title text kind audience changes references follow_on)),
        else: row.event

    event =
      if audience == :player,
        do:
          Map.update(
            event,
            "changes",
            [],
            &Enum.map(&1, fn c -> public_change(c, row.payload) end)
          ),
        else: event

    event
    |> EventReferences.published(row.payload)
    |> Map.put("key", row.event["id"])
    |> Map.put("id", "#{row.tick_id}:#{row.event["id"]}")
    |> Map.put("tick_id", row.tick_id)
    |> Map.put("tick_number", row.number)
  end

  # Public clock visibility does not make its triggers, race partners or DM metadata public.
  defp public_change(change, payload) do
    fields =
      if change["entity"] == "clock",
        do:
          ~w(id name filled segments background_rate paused completed mode influences empty_description full_description tension_id visibility),
        else: ~w(id name description status audience)

    ids = payload["published_entity_ids"] || %{}

    context = fn
      nil ->
        nil

      r ->
        r
        |> Map.take(fields)
        |> Map.new(fn {k, v} ->
          {k, if(k in ~w(id tension_id), do: Map.get(ids, v, v), else: v)}
        end)
    end

    %{
      "entity" => change["entity"],
      "id" => Map.get(ids, change["id"], change["id"]),
      "before" => context.(change["before"]),
      "after" => context.(change["after"])
    }
  end

  defp neighbor(base, row, direction) do
    key = row.event["id"]

    q =
      if direction == :earlier do
        base
        |> where(
          [t, p, e],
          fragment(
            "(?, ?, ?->>'id') < (?, ?, ?)",
            t.number,
            t.id,
            e.value,
            ^row.number,
            ^row.tick_id,
            ^key
          )
        )
        |> order_by([t, p, e], desc: t.number, desc: t.id, desc: fragment("?->>'id'", e.value))
      else
        base
        |> where(
          [t, p, e],
          fragment(
            "(?, ?, ?->>'id') > (?, ?, ?)",
            t.number,
            t.id,
            e.value,
            ^row.number,
            ^row.tick_id,
            ^key
          )
        )
        |> order_by([t, p, e], asc: t.number, asc: t.id, asc: fragment("?->>'id'", e.value))
      end

    case q |> limit(1) |> Repo.one() do
      nil -> nil
      r -> project(r) |> Map.take(~w(id tick_id tick_number key title))
    end
  end
end
