defmodule AsyncWorlds.Discord.ContentTest do
  use ExUnit.Case, async: true
  alias AsyncWorlds.Discord.Content

  test "emoji and combining graphemes stay intact with a conservative Discord bound" do
    grapheme = "👩‍🚀é漢🌍"
    text = String.duplicate(grapheme, 1000)
    chunks = Content.unicode_chunks(text)
    assert Enum.join(chunks) == text
    assert length(chunks) > 1

    for chunk <- chunks do
      assert String.valid?(chunk)
      assert byte_size(:unicode.characters_to_binary(chunk, :utf8, {:utf16, :big})) <= 3800
      assert Enum.all?(String.graphemes(chunk), &(&1 in String.graphemes(grapheme)))
    end
  end

  test "oversized graphemes remain bounded and lossless; empty and invalid UTF-8 are explicit" do
    text = "e" <> String.duplicate("́", 4000)
    assert Enum.join(Content.unicode_chunks(text)) == text
    assert Enum.all?(Content.unicode_chunks(text), &(length(String.codepoints(&1)) <= 1900))
    assert Content.unicode_chunks("") == []
    assert_raise ArgumentError, fn -> Content.unicode_chunks(<<255>>) end
  end
end
