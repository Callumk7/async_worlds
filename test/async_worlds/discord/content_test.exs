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

  test "formatted replies keep complete headings, commands and list lines together" do
    line = "- `/quest` — " <> String.duplicate("x", 120) <> "\n"
    text = "## Player commands\n" <> String.duplicate(line, 40)
    chunks = Content.formatted_chunks(text)

    assert Enum.join(chunks) == text
    assert length(chunks) > 1

    for chunk <- chunks do
      assert byte_size(:unicode.characters_to_binary(chunk, :utf8, {:utf16, :big})) <= 3800

      assert Enum.all?(String.split(chunk, "\n", trim: true), fn item ->
               item == "## Player commands" or item == String.trim_trailing(line)
             end)
    end
  end

  test "formatted replies preserve blank lines, Unicode and oversized authored lines" do
    text = "## Journal\n\n" <> String.duplicate("👩‍🚀é漢🌍", 1000) <> "\n\nEnd\n"
    chunks = Content.formatted_chunks(text)
    assert Enum.join(chunks) == text
    assert Content.formatted_chunks("") == []

    for chunk <- chunks do
      assert String.valid?(chunk)
      assert byte_size(:unicode.characters_to_binary(chunk, :utf8, {:utf16, :big})) <= 3800
    end
  end

  test "quest page budgets count emoji as UTF-16 units" do
    text = String.duplicate("🌍", 2000)
    chunks = Content.unicode_chunks(text, 1400)
    assert Enum.join(chunks) == text

    assert Enum.all?(
             chunks,
             &(byte_size(:unicode.characters_to_binary(&1, :utf8, {:utf16, :big})) <= 2800)
           )
  end

  test "oversized graphemes remain bounded and lossless; empty and invalid UTF-8 are explicit" do
    text = "e" <> String.duplicate("́", 4000)
    assert Enum.join(Content.unicode_chunks(text)) == text
    assert Enum.all?(Content.unicode_chunks(text), &(length(String.codepoints(&1)) <= 1900))
    assert Content.unicode_chunks("") == []
    assert_raise ArgumentError, fn -> Content.unicode_chunks(<<255>>) end
  end
end
