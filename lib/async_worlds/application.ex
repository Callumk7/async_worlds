defmodule AsyncWorlds.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      AsyncWorldsWeb.Telemetry,
      AsyncWorlds.Repo,
      {DNSCluster, query: Application.get_env(:async_worlds, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: AsyncWorlds.PubSub},
      # Start a worker by calling: AsyncWorlds.Worker.start_link(arg)
      # {AsyncWorlds.Worker, arg},
      # Start to serve requests, typically the last entry
      AsyncWorldsWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: AsyncWorlds.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    AsyncWorldsWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
