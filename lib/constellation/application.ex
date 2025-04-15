defmodule Constellation.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  def application do
    [
      mod: {Constellation.Application, []},
      extra_applications: [:logger, :runtime_tools, :tesla]
    ]
  end

  @impl true
  def start(_type, _args) do
    # Load environment variables from .env file in development
    if Mix.env() in [:dev, :test] do
      DotenvParser.load_file(".env")
    end

    children = [
      ConstellationWeb.Telemetry,
      Constellation.Repo,
      {DNSCluster, query: Application.get_env(:constellation, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Constellation.PubSub},
      # Start the Finch HTTP client for sending emails
      {Finch, name: Constellation.Finch},
      # Start a worker by calling: Constellation.Worker.start_link(arg)
      # {Constellation.Worker, arg},
      # Start Presence for tracking players in games
      ConstellationWeb.Presence,
      # Add Task Supervisor for managing async tasks
      {Task.Supervisor, name: Constellation.TaskSupervisor},
      # Start to serve requests, typically the last entry
      ConstellationWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Constellation.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ConstellationWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
