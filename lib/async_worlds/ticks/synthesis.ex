defmodule AsyncWorlds.Ticks.Synthesis do
  @moduledoc "DM-only interpretation of frozen participation; no mechanical or delivery effects."

  def entries(data) do
    entries = Enum.flat_map(data["tension_commitments"] || [], & &1["commitments"])
    names = Map.new(get_in(data, ["quest_inputs", "characters"]) || [], &{&1["id"], &1["name"]})

    entries
    |> Enum.sort_by(&{&1["tension_id"], &1["character_id"]})
    |> Enum.map(fn entry ->
      %{
        entry: entry,
        name: names[entry["character_id"]],
        anchor: anchor(entry),
        elsewhere:
          entries
          |> Enum.filter(
            &(&1["character_id"] == entry["character_id"] and
                &1["tension_id"] != entry["tension_id"] and
                &1["state"] in ["confirmed", "unresolved"])
          )
          |> Enum.sort_by(& &1["tension_id"])
      }
    end)
  end

  def anchor(entry),
    do: "intent-#{entry["tension_id"]}-#{entry["character_id"]}-v#{entry["version"]}"

  def apply_operation(review, %{"type" => "synthesis", "tension_id" => id} = op)
      when is_integer(id) do
    note = Map.take(op, ["interpretation", "deferred"])
    Map.update(review, "synthesis", %{to_string(id) => note}, &Map.put(&1, to_string(id), note))
  end

  def apply_operation(_, _), do: raise(ArgumentError, "invalid synthesis")

  def validate!(data, review) do
    notes = Map.get(review, "synthesis", %{})
    true = is_map(notes)

    Enum.each(notes, fn {id, note} ->
      valid? =
        Enum.any?(data["tensions"] || [], &(to_string(&1["id"]) == id)) and
          is_map(note) and Enum.sort(Map.keys(note)) == ["deferred", "interpretation"] and
          text?(note["interpretation"]) and is_list(note["deferred"])

      unless valid?, do: raise(ArgumentError, "invalid synthesis")

      ids =
        for row <- entries(data),
            to_string(row.entry["tension_id"]) == id,
            do: row.entry["character_id"]

      unless Enum.all?(note["deferred"], &(&1 in ids)) and
               Enum.uniq(note["deferred"]) == note["deferred"],
             do: raise(ArgumentError, "invalid frozen participation")
    end)

    :ok
  end

  defp text?(text),
    do:
      is_binary(text) and String.valid?(text) and not String.contains?(text, <<0>>) and
        String.length(text) <= 8000
end
