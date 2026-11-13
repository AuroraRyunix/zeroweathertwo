defmodule ZeroWeather.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      ZeroWeatherWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:zero_weather, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: ZeroWeather.PubSub},
      ZeroWeather.Cache,
      # Start to serve requests, typically the last entry
      ZeroWeatherWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: ZeroWeather.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ZeroWeatherWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
