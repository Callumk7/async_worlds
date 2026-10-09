defmodule AsyncWorlds.WebAuth.OAuthState do
  @moduledoc false
  use Ecto.Schema

  schema "oauth_states" do
    field :token_hash, :binary
    field :expires_at, :utc_datetime

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
