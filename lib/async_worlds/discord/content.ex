defmodule AsyncWorlds.Discord.Content do
  @moduledoc "Discord content chunking. Legacy codepoint boundaries and conservative grapheme-safe opening chunks."
  @limit 1900

  # Keep existing command pagination and stored output boundaries unchanged.
  def chunks(content) when is_binary(content) do
    content
    |> String.codepoints()
    |> Enum.chunk_every(@limit)
    |> Enum.map(&Enum.join/1)
  end

  def unicode_chunks(content) when is_binary(content) do
    unless String.valid?(content), do: raise(ArgumentError, "content must be valid UTF-8")

    content
    |> String.graphemes()
    |> Enum.flat_map(&bounded_parts/1)
    |> Enum.reduce({[], [], 0}, &append/2)
    |> finish()
  end

  # Pathological combining sequences can exceed a whole message. Split those
  # at codepoint boundaries rather than truncate, emit invalid UTF-8 or oversize.
  defp bounded_parts(grapheme) do
    if units(grapheme) <= @limit, do: [grapheme], else: String.codepoints(grapheme)
  end

  defp append(part, {chunks, current, size}) do
    length = units(part)

    if size + length > @limit do
      {[join(current) | chunks], [part], length}
    else
      {chunks, [part | current], size + length}
    end
  end

  defp finish({chunks, [], _}), do: Enum.reverse(chunks)
  defp finish({chunks, current, _}), do: Enum.reverse([join(current) | chunks])
  defp join(parts), do: parts |> Enum.reverse() |> IO.iodata_to_binary()

  defp units(text),
    do: div(byte_size(:unicode.characters_to_binary(text, :utf8, {:utf16, :big})), 2)
end
