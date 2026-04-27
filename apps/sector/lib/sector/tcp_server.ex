defmodule Sector.TcpServer do
  @moduledoc """

  Servidor TCP para comunicação com outros setores e drones.
  Esse é o principal canal de setores e drones se comunicarem, enviando mensagens de status, comandos e atualizações de posição.
  Ao iniciar o setor, o servidor TCP é iniciado em uma porta específica (definida na configuração do setor) e fica escutando por conexões de clientes (outros setores e drones).

  """

  use GenServer
  require Logger

  alias Core.Protocol.Message

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(port) do
    case(:gen_tcp.listen(port, [:binary, packet: :line, active: true, reuseaddr: true])) do
      {:ok, socket} ->
        Logger.info("TCP server started on port #{port}")

        send(self(), :accept)

        {:ok, %{socket: socket}}

      {:error, reason} ->
        Logger.error("Failed to start TCP server: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def handle_info(:accept, state) do
    Task.start_link(fn ->
      case :gen_tcp.accept(state.socket) do
        {:ok, client_socket} ->
          Logger.info("Client connected")
          :ok = :gen_tcp.controlling_process(client_socket, Process.whereis(__MODULE__))
          send(Process.whereis(__MODULE__), :accept)

        {:error, _} ->
          :ok
      end
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info({:tcp, socket, data}, state) do
    data
    |> String.trim()
    |> decode_and_handle(socket)

    {:noreply, state}
  end

  defp decode_and_handle(data, socket) do
    case JSON.decode(data) do
      {:ok, map} -> handle_map(map, socket)
      {:error, reason} -> Logger.error("Failed to decode JSON: #{inspect(reason)}")
    end
  end

  defp handle_map(map, socket) do
    case Message.from_map(map) do
      {:ok, %Message{type: type, from: from} = msg} ->
        Logger.info("Received message type: #{inspect(type)} from: #{from}")
        Task.start(fn -> handle_message(msg, socket) end)

      {:error, :invalid_message} ->
        Logger.error("Message has invalid format: #{inspect(map)}")
    end
  end

  defp handle_message(%Message{type: :ping, from: from}, socket) do
    Logger.info("Received ping from #{inspect(from)}")

    response = %Message{
      type: :pong,
      from: Sector.NodeId.get(),
      payload: "Pong response to #{from}"
    }

    encoded_response = JSON.encode!(response) <> "\n"
    :gen_tcp.send(socket, encoded_response)
  end
end
