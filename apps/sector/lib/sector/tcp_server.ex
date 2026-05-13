defmodule Sector.TcpServer do
  @moduledoc """
  Servidor TCP para comunicação com outros setores e drones.
  """

  use GenServer
  require Logger

  alias Core.Protocol.{
    DroneStatus,
    Message,
    MissionAck,
    MissionReject,
    Reply,
    Request,
    SensorRequest,
    SensorStatus
  }

  def start_link(port) when is_integer(port) do
    GenServer.start_link(__MODULE__, port, name: __MODULE__)
  end

  def broadcast(message) do
    GenServer.cast(__MODULE__, {:broadcast, message})
  end

  @impl true
  def init(port) do
    case :gen_tcp.listen(port, [:binary, packet: :line, active: false, reuseaddr: true]) do
      {:ok, socket} ->
        Logger.info("TCP server started on port #{port}")
        send(self(), :accept)

        {:ok,
         %{
           socket: socket,
           clients: [],
           pending_auth: %{},
           drone_sockets: %{},
           sensor_sockets: %{}
         }}

      {:error, reason} ->
        Logger.error("Failed to start TCP server: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def handle_info({:tcp, socket, data}, state) do
    trimmed_data = String.trim(data)

    case JSON.decode(trimmed_data) do
      {:ok, map} ->
        process_tcp_message(map, socket, state)

      {:error, reason} ->
        :gen_tcp.close(socket)
        Logger.error("Failed to decode JSON: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:accept, state) do
    Task.start_link(fn ->
      case :gen_tcp.accept(state.socket) do
        {:ok, client_socket} ->
          :inet.setopts(client_socket, active: false)
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
    Logger.info("Client connected. Aguardando autenticacao...")
    timer = Process.send_after(self(), {:auth_timeout, client_socket}, 3000)

    :inet.setopts(client_socket, active: :once)

    {:noreply, %{state | pending_auth: Map.put(state.pending_auth, client_socket, timer)}}
  end

  @impl true
  def handle_info({:auth_timeout, socket}, state) do
    if Map.has_key?(state.pending_auth, socket) do
      Logger.warning("Timeout de autenticacao. Fechando conexao.")
      :gen_tcp.close(socket)
      {:noreply, %{state | pending_auth: Map.delete(state.pending_auth, socket)}}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:tcp_closed, socket}, state) do
    Logger.info("Conexão de um cliente fechada pelo outro lado.")
    new_pending = Map.delete(state.pending_auth, socket)
    new_clients = List.delete(state.clients, socket)
    {drone_id, new_drone_sockets} = Map.pop(state.drone_sockets, socket)
    {sensor_id, new_sensor_sockets} = Map.pop(state.sensor_sockets, socket)

    if drone_id, do: Sector.Node.drone_disconnected(drone_id)
    if sensor_id, do: Sector.Node.sensor_disconnected(sensor_id)

    {:noreply,
     %{
       state
       | pending_auth: new_pending,
         clients: new_clients,
         drone_sockets: new_drone_sockets,
         sensor_sockets: new_sensor_sockets
     }}
  end

  @impl true
  def handle_info({:tcp_error, socket, reason}, state) do
    Logger.error("Erro na conexão TCP do cliente: #{inspect(reason)}")
    new_pending = Map.delete(state.pending_auth, socket)
    new_clients = List.delete(state.clients, socket)
    {drone_id, new_drone_sockets} = Map.pop(state.drone_sockets, socket)
    {sensor_id, new_sensor_sockets} = Map.pop(state.sensor_sockets, socket)

    if drone_id, do: Sector.Node.drone_disconnected(drone_id)
    if sensor_id, do: Sector.Node.sensor_disconnected(sensor_id)

    {:noreply,
     %{
       state
       | pending_auth: new_pending,
         clients: new_clients,
         drone_sockets: new_drone_sockets,
         sensor_sockets: new_sensor_sockets
     }}
  end

  @impl true
  def handle_cast({:broadcast, message}, state) do
    Enum.each(state.clients, fn socket ->
      :gen_tcp.send(socket, message)
    end)

    {:noreply, state}
  end

  defp handle_auth(%{"type" => "auth", "passkey" => passkey}, socket, state) do
    if passkey == Core.Auth.get_hashed_passkey() do
      Logger.info("Cliente autenticado com sucesso!")

      # Lidando com o timer sem adicionar aninhamento
      cancel_auth_timer(Map.get(state.pending_auth, socket))

      new_state = %{
        state
        | pending_auth: Map.delete(state.pending_auth, socket),
          clients: [socket | state.clients]
      }

      :inet.setopts(socket, active: :once)
      {:noreply, new_state}
    else
      Logger.warning("Falha na autenticacao. Passkey incorreta.")
      reject_connection(socket, state)
    end
  end

  defp handle_auth(_map, socket, state) do
    Logger.warning("Primeira mensagem nao foi auth. Fechando conexao.")
    reject_connection(socket, state)
  end

  defp cancel_auth_timer(nil), do: :ok
  defp cancel_auth_timer(timer), do: Process.cancel_timer(timer)

  defp reject_connection(socket, state) do
    :gen_tcp.close(socket)
    {:noreply, %{state | pending_auth: Map.delete(state.pending_auth, socket)}}
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

  defp dispatch_message(%{"type" => "sensor_status"} = map, _socket) do
    case SensorStatus.from_map(map) do
      {:ok, status} -> Sector.Node.process_network_message(status)
      {:error, reason} -> Logger.error("SensorStatus inválido: #{inspect(reason)}")
    end
  end

  defp dispatch_message(%{"type" => "sensor_request"} = map, _socket) do
    case SensorRequest.from_map(map) do
      {:ok, request} -> Sector.Node.process_network_message(request)
      {:error, reason} -> Logger.error("SensorRequest inválido: #{inspect(reason)}")
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

  defp process_tcp_message(map, socket, state) do
    if Map.has_key?(state.pending_auth, socket) do
      handle_auth(map, socket, state)
    else
      state = update_state_sockets(map, socket, state)

      dispatch_message(map, socket)
      :inet.setopts(socket, active: :once)
      {:noreply, state}
    end
  end

  defp update_state_sockets(%{"type" => "drone_status", "drone_id" => id}, socket, state) do
    %{state | drone_sockets: Map.put(state.drone_sockets, socket, id)}
  end

  defp update_state_sockets(%{"type" => "sensor_status", "sensor_id" => id}, socket, state) do
    %{state | sensor_sockets: Map.put(state.sensor_sockets, socket, id)}
  end

  defp update_state_sockets(_map, _socket, state), do: state
end
