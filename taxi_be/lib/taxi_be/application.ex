defmodule TaxiBe.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      TaxiBeWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:taxi_be, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: TaxiBe.PubSub},
      # Start the Finch HTTP client for sending emails
      {Finch, name: TaxiBe.Finch},
      # Start a worker by calling: TaxiBe.Worker.start_link(arg)
      # {TaxiBe.Worker, arg},
      # Start to serve requests, typically the last entry
      TaxiBeWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: TaxiBe.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    TaxiBeWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
