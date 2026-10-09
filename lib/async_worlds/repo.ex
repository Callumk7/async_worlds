defmodule AsyncWorlds.Repo do
  use Ecto.Repo,
    otp_app: :async_worlds,
    adapter: Ecto.Adapters.Postgres
end
