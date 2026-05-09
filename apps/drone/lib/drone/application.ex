defmodule Drone.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    drone_id = UUIDv7.generate()

    children =
      if Mix.env() == :test do
        []
      else
        [
          Drone.TcpClient,
          {Drone.Worker, [drone_id: drone_id]}
        ]
      end

    opts = [strategy: :one_for_one, name: Drone.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
