defmodule Graphism.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  def start(_type, _args) do
    children = [
      # Start the Ecto repository
      Graphism.Repo,
      # Start the Telemetry supervisor
      GraphismWeb.Telemetry,
      # Start the PubSub system
      {Phoenix.PubSub, name: Graphism.PubSub},
      # Start the Endpoint (http/https)
      GraphismWeb.Endpoint
      # Start a worker by calling: Graphism.Worker.start_link(arg)
      # {Graphism.Worker, arg}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Graphism.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  def config_change(changed, _new, removed) do
    GraphismWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
