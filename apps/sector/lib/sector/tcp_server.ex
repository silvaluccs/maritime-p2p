defmodule Sector.TcpServer do
  @moduledoc """

  Servidor TCP para comunicação com outros setores e drones.
  Esse é o principal canal de setores e drones se comunicarem, enviando mensagens de status, comandos e atualizações de posição.
  Ao iniciar o setor, o servidor TCP é iniciado em uma porta específica (definida na configuração do setor) e fica escutando por conexões de clientes (outros setores e drones).

  """

  use GenServer
  require Logger

  alias Core.Protocol.{DroneStatus, Message, MissionAck, MissionReject, Reply, Request}

  def start_link(port) when is_integer(port) do
    GenServer.start_link(__MODULE__, port, name: __MODULE__)
  end

  def broadcast(message) do
    GenServer.cast(__MODULE__, {:broadcast, message})
  end

  @impl true
  def init(port) do
    case(:gen_tcp.listen(port, [:binary, packet: :line, active: :once, reuseaddr: true])) do
      {:ok, socket} ->
        Logger.info("TCP server started on port #{port}")

        send(self(), :accept)

        {:ok, %{socket: socket, clients: [], drone_sockets: %{}}}

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
          :ok = :gen_tcp.controlling_process(client_socket, Process.whereis(__MODULE__))
          send(Process.whereis(__MODULE__), {:new_client, client_socket})
          send(Process.whereis(__MODULE__), :accept)

        {:error, _} ->
          :ok
      end
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info({:new_client, client_socket}, state) do
    Logger.info("Client connected")
    {:noreply, %{state | clients: [client_socket | state.clients]}}
  end

  @impl true
  def handle_info({:tcp, socket, data}, state) do
    trimmed_data = String.trim(data)

    new_state =
      case JSON.decode(trimmed_data) do
        {:ok, map} ->
          state =
            if map["type"] == "drone_status" do
              %{state | drone_sockets: Map.put(state.drone_sockets, socket, map["drone_id"])}
            else
              state
            end

          dispatch_message(map, socket)
          state

        {:error, reason} ->
          Logger.error("Failed to decode JSON: #{inspect(reason)}")
          state
      end

    :inet.setopts(socket, active: :once)

    {:noreply, new_state}
  end

  @impl true
  def handle_info({:tcp_closed, socket}, state) do
    Logger.info("Conexão de um cliente fechada pelo outro lado.")
    new_clients = List.delete(state.clients, socket)
    {drone_id, new_drone_sockets} = Map.pop(state.drone_sockets, socket)

    if drone_id do
      Sector.Node.drone_disconnected(drone_id)
    end

    {:noreply, %{state | clients: new_clients, drone_sockets: new_drone_sockets}}
  end

  @impl true
  def handle_info({:tcp_error, socket, reason}, state) do
    Logger.error("Erro na conexão TCP do cliente: #{inspect(reason)}")
    new_clients = List.delete(state.clients, socket)
    {drone_id, new_drone_sockets} = Map.pop(state.drone_sockets, socket)

    if drone_id do
      Sector.Node.drone_disconnected(drone_id)
    end

    {:noreply, %{state | clients: new_clients, drone_sockets: new_drone_sockets}}
  end

  @impl true
  def handle_cast({:broadcast, message}, state) do
    Enum.each(state.clients, fn socket ->
      :gen_tcp.send(socket, message)
    end)

    {:noreply, state}
  end

  defp dispatch_message(%{"type" => "request"} = map, _socket) do
    case Request.from_map(map) do
      {:ok, request} -> Sector.Node.process_network_message(request)
      {:error, reason} -> Logger.error("Request inválido: #{inspect(reason)}")
    end
  end

  defp dispatch_message(%{"type" => "reply"} = map, _socket) do
    case Reply.from_map(map) do
      {:ok, reply} -> Sector.Node.process_network_message(reply)
      {:error, reason} -> Logger.error("Reply inválido: #{inspect(reason)}")
    end
  end

  defp dispatch_message(%{"type" => "drone_status"} = map, _socket) do
    case DroneStatus.from_map(map) do
      {:ok, status} -> Sector.Node.process_network_message(status)
      {:error, reason} -> Logger.error("DroneStatus inválido: #{inspect(reason)}")
    end
  end

  defp dispatch_message(%{"type" => "mission_ack"} = map, _socket) do
    case MissionAck.from_map(map) do
      {:ok, ack} -> Sector.Node.process_network_message(ack)
      {:error, reason} -> Logger.error("MissionAck inválido: #{inspect(reason)}")
    end
  end

  defp dispatch_message(%{"type" => "mission_reject"} = map, _socket) do
    case MissionReject.from_map(map) do
      {:ok, reject} -> Sector.Node.process_network_message(reject)
      {:error, reason} -> Logger.error("MissionReject inválido: #{inspect(reason)}")
    end
  end

  defp dispatch_message(%{"type" => type} = map, socket) when type in ["ping", "pong"] do
    case Message.from_map(map) do
      {:ok, msg} -> Task.start(fn -> handle_message(msg, socket) end)
      {:error, _} -> Logger.error("Ping/Pong inválido: #{inspect(map)}")
    end
  end

  defp dispatch_message(map, _socket) do
    Logger.warning("Tipo de mensagem desconhecido: #{inspect(map)}")
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
