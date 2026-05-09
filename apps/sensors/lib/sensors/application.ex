defmodule Sensors.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    sensor_id = UUIDv7.generate()

    children =
      if Mix.env() == :test do
        []
      else
        [{Sensors.Worker, [sensor_id: sensor_id]}]
      end

    opts = [strategy: :one_for_one, name: Sensors.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
