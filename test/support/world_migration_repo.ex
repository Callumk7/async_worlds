defmodule AsyncWorlds.WorldMigrationRepo do
  @moduledoc false
  use Ecto.Repo, otp_app: :async_worlds, adapter: Ecto.Adapters.Postgres
end
