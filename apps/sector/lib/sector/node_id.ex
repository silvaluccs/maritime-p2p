defmodule Sector.NodeId do
  @moduledoc """

  Modulo responsavel por gerar e armazenar o Node ID do setor. O Node ID é um identificador único para cada setor, utilizado para identificar o setor nas comunicações com outros setores e drones. Ele é gerado utilizando o UUIDv7, garantindo que cada setor tenha um identificador único e fácil de rastrear.

  """
  use GenServer

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def init(_) do
    {:ok, UUIDv7.generate()}
  end

  def get, do: GenServer.call(__MODULE__, :get)

  @impl true
  def handle_call(:get, _from, node_id) do
    {:reply, node_id, node_id}
  end
end
