defmodule AsyncWorlds.Journals.Entry do
  @moduledoc "Character-owned journal content. Trusted attribution is never cast from input."
  use Ecto.Schema
  import Ecto.Changeset

  schema "journal_entries" do
    field :campaign_id, :id
    field :character_id, :id
    field :receipt_id, Ecto.UUID
    field :author_discord_user_id, AsyncWorlds.Discord.Snowflake
    field :origin, Ecto.Enum, values: [:player, :dm_persona]
    field :visibility, Ecto.Enum, values: [:private, :public], default: :private
    field :title, :string
    field :body, :string
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [:title, :body])
    |> validate_required([:title, :body])
    |> validate_change(:title, &validate_text(&1, &2, 100))
    |> validate_change(:body, &validate_text(&1, &2, 4000))
    |> check_constraint(:title, name: :journal_title_valid)
    |> check_constraint(:body, name: :journal_body_valid)
    |> unique_constraint(:receipt_id)
  end

  def valid_text?(text, max) when is_binary(text) do
    byte_size(text) <= max * 4 and String.valid?(text) and
      not String.contains?(text, <<0>>) and String.trim(text) != "" and
      length(String.codepoints(text)) <= max
  end

  def valid_text?(_, _), do: false

  defp validate_text(field, value, max) do
    if valid_text?(value, max),
      do: [],
      else: [{field, "must be nonblank and at most #{max} Unicode codepoints"}]
  end
end
