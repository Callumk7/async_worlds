defmodule AsyncWorlds.Ticks.ManualWorld do
  @moduledoc "Frozen manual intentions, replayed once after background resolution. Tensions remain DM-only."
  alias AsyncWorlds.Clocks.Clock
  alias AsyncWorlds.Tensions.Tension

  def apply_operation(review, %{"type" => "world", "key" => key, "event" => event})
      when is_binary(key) and byte_size(key) in 1..100 do
    bundles = Map.get(review, "world", %{})
    bundles = if is_nil(event), do: Map.delete(bundles, key), else: Map.put(bundles, key, event)
    Map.put(review, "world", bundles)
  end

  def apply_operation(_, _), do: raise(ArgumentError, "invalid manual operation")

  def project(payload, data, review) do
    if data["manual_world"] do
      initial = %{
        clocks: payload["clocks"],
        tensions: data["tensions"],
        context: data["event_context"] || [],
        events: [],
        changes: []
      }

      state =
        review
        |> Map.get("world", %{})
        |> Enum.sort()
        |> Enum.reduce(initial, fn {key, event}, state -> bundle(state, key, event) end)

      prompts =
        for c <- state.clocks,
            c["tension_id"] && not c["completed"] && c["filled"] in [0, c["segments"]],
            Enum.any?(
              state.tensions,
              &(&1["id"] == c["tension_id"] and &1["status"] == "ongoing")
            ),
            do: %{
              "clock_id" => c["id"],
              "name" => c["name"],
              "endpoint" => if(c["filled"] == 0, do: "empty", else: "full")
            }

      Map.merge(payload, %{
        "clocks" => state.clocks,
        "tensions" => state.tensions,
        "events" => state.events,
        "manual_changes" => state.changes,
        "endpoint_prompts" => prompts
      })
    else
      if Map.get(review, "world", %{}) != %{}, do: raise(ArgumentError, "legacy snapshot")
      payload
    end
  end

  defp bundle(state, key, event) do
    true = is_map(event)
    true = event["audience"] in ["dm", "public"]
    title = event["title"]
    text = event["text"]
    true = valid_text?(title, 200) and valid_text?(text, 2000)
    true = is_list(event["changes"]) and length(event["changes"]) <= 100
    true = event["kind"] in ["event", "resolution", "routine"]
    true = event["kind"] == "routine" or String.trim(title) != ""
    start = length(state.changes)
    original_tensions = state.tensions

    state =
      event["changes"]
      |> Enum.with_index()
      |> Enum.reduce(state, fn {change, index}, acc ->
        change(acc, change, "new:#{key}:#{index}", key)
      end)

    changes = Enum.drop(state.changes, start)

    if event["audience"] == "public" do
      true =
        Enum.all?(changes, fn c ->
          public_change?(c, state.tensions) and
            public_change?(c, original_tensions ++ state.tensions)
        end)
    end

    resolved =
      Enum.filter(changes, &(&1["entity"] == "tension" and &1["after"]["status"] == "resolved"))

    true =
      (event["kind"] == "resolution" and resolved != []) or
        (event["kind"] != "resolution" and resolved == [])

    event = AsyncWorlds.Ticks.EventReferences.attach(event, state, original_tensions, changes)
    saved = Map.merge(event, %{"id" => key, "changes" => changes})
    %{state | events: state.events ++ if(event["kind"] == "routine", do: [], else: [saved])}
  end

  defp change(state, %{"entity" => entity, "id" => id, "attrs" => attrs}, temp, key)
       when entity in ["clock", "tension"] and is_map(attrs) do
    field = if entity == "clock", do: :clocks, else: :tensions
    records = Map.fetch!(state, field)
    before = if id, do: Enum.find(records, &(&1["id"] == id))
    true = is_nil(id) or not is_nil(before)
    true = entity != "clock" or is_nil(before) or not before["completed"]
    before_struct = if entity == "clock", do: %Clock{visibility: :hidden}, else: %Tension{}
    # Only schema-defined fields are cast; IDs, ownership, triggers and races cannot be injected.
    base =
      if before,
        do: Map.merge(before_struct, atom_fields(before, before_struct)),
        else: before_struct

    allowed =
      if entity == "clock",
        do:
          ~w(name segments filled visibility background_rate paused mode influences empty_description full_description delta tension_id),
        else: ~w(name description status audience)

    true = Enum.all?(Map.keys(attrs), &(&1 in allowed))

    attrs =
      if Map.has_key?(attrs, "delta") do
        true =
          entity == "clock" and not is_nil(before) and is_integer(attrs["delta"]) and
            not before["completed"]

        Map.put(attrs, "filled", before["filled"] + attrs["delta"]) |> Map.delete("delta")
      else
        attrs
      end

    cs =
      if entity == "clock", do: Clock.changeset(base, attrs), else: Tension.changeset(base, attrs)

    true = cs.valid?
    after_record = Ecto.Changeset.apply_changes(cs) |> snapshot()
    after_record = Map.put(after_record, "id", id || temp)

    after_record =
      if entity == "tension" do
        status = Map.get(attrs, "status", if(before, do: before["status"], else: "ongoing"))
        true = status in ["ongoing", "resolved"]
        true = is_nil(before) or before["status"] != "resolved"

        after_record
        |> Map.put("status", status)
        |> Map.put("revision", if(before, do: before["revision"] + 1, else: 1))
      else
        tension_id = Map.get(attrs, "tension_id", after_record["tension_id"])

        true =
          is_nil(tension_id) or
            Enum.any?(
              state.tensions,
              &(&1["id"] == tension_id and (&1["status"] == "ongoing" or after_record["paused"]))
            )

        after_record
        |> Map.put("tension_id", tension_id)
        |> Map.put(
          "association_revision",
          (after_record["association_revision"] || 0) +
            if(before && before["tension_id"] != tension_id, do: 1, else: 0)
        )
      end

    preserved =
      if entity == "tension", do: Map.delete(before || %{}, "audience"), else: before || %{}

    after_record = Map.merge(preserved, after_record)

    entry = %{
      "entity" => entity,
      "id" => after_record["id"],
      "before" => before,
      "after" => after_record,
      "source" => key
    }

    records =
      if id,
        do: Enum.map(records, &if(&1["id"] == id, do: after_record, else: &1)),
        else: records ++ [after_record]

    state = state |> Map.put(field, records) |> Map.update!(:changes, &(&1 ++ [entry]))

    if entity == "tension" and after_record["status"] == "resolved" do
      state.clocks
      |> Enum.filter(
        &(&1["tension_id"] == after_record["id"] and not &1["paused"] and not &1["completed"])
      )
      |> Enum.reduce(state, fn clock, acc ->
        change(
          acc,
          %{"entity" => "clock", "id" => clock["id"], "attrs" => %{"paused" => true}},
          temp,
          key
        )
      end)
    else
      state
    end
  end

  defp atom_fields(map, struct) do
    for key <- Map.keys(struct),
        Map.has_key?(map, to_string(key)) or key == :audience,
        key not in [:__struct__, :__meta__, :triggers],
        into: %{} do
      value = if key == :audience, do: Map.get(map, "audience", "dm"), else: map[to_string(key)]

      value =
        if key in [:visibility, :mode, :status, :audience] and is_binary(value),
          do: String.to_existing_atom(value),
          else: value

      {key, value}
    end
  end

  def snapshot(%Clock{} = c),
    do:
      c
      |> Map.from_struct()
      |> Map.take(
        ~w(id campaign_id tension_id association_revision mode influences empty_description full_description name segments filled visibility background_rate paused completed racing_group)a
      )
      |> json()

  # Absence means DM-only, preserving replay shape for pre-ENG-92 snapshots.
  def snapshot(%Tension{} = t),
    do:
      t
      |> Map.from_struct()
      |> Map.take(~w(id campaign_id name description status revision)a)
      |> then(fn fields ->
        if t.audience == :public, do: Map.put(fields, :audience, :public), else: fields
      end)
      |> json()

  defp public_change?(change, tensions) do
    Enum.all?([change["before"], change["after"]], fn
      nil ->
        true

      record ->
        if change["entity"] == "tension" do
          record["audience"] == "public"
        else
          record["visibility"] == "public" and
            (is_nil(record["tension_id"]) or
               public_tension?(tensions, record["tension_id"]))
        end
    end)
  end

  defp public_tension?(tensions, id) do
    case Enum.find(tensions, &(&1["id"] == id)) do
      %{"audience" => "public"} -> true
      _ -> false
    end
  end

  defp json(value), do: Jason.decode!(Jason.encode!(value))

  defp valid_text?(v, max),
    do:
      is_binary(v) and String.valid?(v) and not String.contains?(v, <<0>>) and
        String.length(v) <= max

  def persist!(campaign_id, tick_id, payload) do
    Enum.reduce(payload["manual_changes"] || [], %{}, fn c, ids ->
      module = if c["entity"] == "clock", do: Clock, else: Tension

      record =
        if c["before"],
          do:
            AsyncWorlds.Repo.get_by!(module,
              campaign_id: campaign_id,
              id: Map.get(ids, c["id"], c["id"])
            ),
          else: struct(module, campaign_id: campaign_id)

      attrs = atom_fields(c["after"], record) |> Map.drop([:id, :campaign_id])

      attrs =
        if attrs[:tension_id],
          do: Map.update!(attrs, :tension_id, &Map.get(ids, &1, &1)),
          else: attrs

      cs = Ecto.Changeset.change(record, attrs)
      saved = if c["before"], do: AsyncWorlds.Repo.update!(cs), else: AsyncWorlds.Repo.insert!(cs)

      if c["entity"] == "clock" do
        AsyncWorlds.Repo.insert!(%AsyncWorlds.Clocks.Audit{
          campaign_id: campaign_id,
          tick_id: tick_id,
          clock_id: saved.id,
          operation: "publish",
          source: "manual:tick:#{tick_id}:#{c["source"]}",
          before: c["before"] || %{},
          after: c["after"]
        })
      end

      if is_binary(c["id"]), do: Map.put(ids, c["id"], saved.id), else: ids
    end)
  end
end
