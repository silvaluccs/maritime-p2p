defmodule Drone.TcpClient do
  @moduledoc """
  TCP client para o Drone. Conecta aos nós (Setores) e repassa mensagens para o Drone.Worker.
  """

  use GenServer
  require Logger

  @default_reconnect_ms 3_000

  # Public API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def connected_peers do
    GenServer.call(__MODULE__, :connected_peers)
  end

  def broadcast(message) when is_binary(message) do
    GenServer.call(__MODULE__, {:broadcast, message})
  end

  def send_to(peer, message) when is_binary(peer) and is_binary(message) do
    GenServer.call(__MODULE__, {:send_to, peer, message})
  end

  # GenServer callbacks

  @impl true
  def init(opts) do
    peers =
      opts
      |> Keyword.get(:peers, parse_peers_from_env())
      |> normalize_peers()
      |> Enum.uniq()

    reconnect_ms = Keyword.get(opts, :reconnect_ms, @default_reconnect_ms)

    Logger.info("TCP Client do Drone iniciando com #{length(peers)} peer(s): #{inspect(peers)}")

    state = %{
      reconnect_ms: reconnect_ms,
      sockets: %{},
      peers: peers
    }

    send(self(), :connect_all)

    {:ok, state}
  end

  @impl true
  def handle_info(:connect_all, state) do
    new_state =
      Enum.reduce(state.peers, state, fn {host, port}, acc ->
        peer = format_peer(host, port)

        if Map.has_key?(acc.sockets, peer) do
          acc
        else
          connect_peer(host, port, acc)
        end
      end)

    {:noreply, new_state}
  end

  @impl true
  def handle_info({:reconnect, {host, port}}, state) do
    peer = format_peer(host, port)

    if Map.has_key?(state.sockets, peer) do
      {:noreply, state}
    else
      {:noreply, connect_peer(host, port, state)}
    end
  end

  @impl true
  def handle_info({:tcp_closed, socket}, state) do
    case find_peer_by_socket(state.sockets, socket) do
      nil ->
        {:noreply, state}

      {peer, _socket} ->
        Logger.warning("Conexão TCP encerrada por #{peer}")

        if Code.ensure_loaded?(Drone.Worker) do
          Drone.Worker.handle_disconnect(peer)
        end

        {host, port} = split_peer(peer)

        new_state =
          state
          |> remove_peer_socket(peer)
          |> schedule_reconnect({host, port})

        {:noreply, new_state}
    end
  end

  @impl true
  def handle_info({:tcp_error, socket, reason}, state) do
    case find_peer_by_socket(state.sockets, socket) do
      nil ->
        {:noreply, state}

      {peer, _socket} ->
        Logger.error("Erro TCP com #{peer}: #{inspect(reason)}")

        if Code.ensure_loaded?(Drone.Worker) do
          Drone.Worker.handle_disconnect(peer)
        end

        {host, port} = split_peer(peer)

        new_state =
          state
          |> remove_peer_socket(peer)
          |> schedule_reconnect({host, port})

        {:noreply, new_state}
    end
  end

  @impl true
  def handle_info({:tcp, socket, data}, state) do
    case find_peer_by_socket(state.sockets, socket) do
      nil ->
        {:noreply, state}

      {peer, _socket} ->
        msg = data |> to_string() |> String.trim_trailing()

        # Repassa para o Worker do Drone
        if Code.ensure_loaded?(Drone.Worker) do
          Drone.Worker.handle_network_message(peer, msg)
        end

        :inet.setopts(socket, active: :once)
        {:noreply, state}
    end
  end

  @impl true
  def handle_call(:connected_peers, _from, state) do
    peers =
      Enum.map(state.sockets, fn {peer, socket} ->
        %{peer: peer, socket: socket}
      end)

    {:reply, peers, state}
  end

  @impl true
  def handle_call({:broadcast, message}, _from, state) do
    payload = ensure_line(message)

    results =
      Enum.map(state.sockets, fn {peer, socket} ->
        res = :gen_tcp.send(socket, payload)

        if res != :ok do
          Logger.error("Falha ao enviar broadcast para #{peer}: #{inspect(res)}")
        end

        {peer, res}
      end)

    {:reply, results, state}
  end

  @impl true
  def handle_call({:send_to, peer, message}, _from, state) do
    case Map.fetch(state.sockets, peer) do
      {:ok, socket} ->
        payload = ensure_line(message)

        case :gen_tcp.send(socket, payload) do
          :ok -> {:reply, :ok, state}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end

      :error ->
        {:reply, {:error, :not_connected}, state}
    end
  end

  # Internal helpers

  defp connect_peer(host, port, state) do
    peer = format_peer(host, port)

    case :gen_tcp.connect(
           String.to_charlist(host),
           port,
           [:binary, packet: :line, active: :once],
           3_000
         ) do
      {:ok, socket} ->
        Logger.info("Drone conectado ao nó #{peer}")

        auth_msg = %Core.Protocol.Auth{
          type: :auth,
          id: System.get_env("DRONE_ID") || "unknown_drone",
          passkey: Core.Auth.get_hashed_passkey()
        }

        :gen_tcp.send(socket, JSON.encode!(auth_msg) <> "\n")

        Map.update!(state, :sockets, &Map.put(&1, peer, socket))

      {:error, _reason} ->
        schedule_reconnect(state, {host, port})
    end
  end

  defp schedule_reconnect(state, {host, port}) do
    Process.send_after(self(), {:reconnect, {host, port}}, state.reconnect_ms)
    state
  end

  defp remove_peer_socket(state, peer) do
    case Map.pop(state.sockets, peer) do
      {nil, sockets} ->
        %{state | sockets: sockets}

      {socket, sockets} ->
        _ = :gen_tcp.close(socket)
        %{state | sockets: sockets}
    end
  end

  defp find_peer_by_socket(sockets, socket) do
    Enum.find(sockets, fn {_peer, s} -> s == socket end)
  end

  defp parse_peers_from_env do
    System.get_env("TCP_PEERS", "")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&(&1 != ""))
    |> Enum.map(&parse_peer!/1)
  end

  defp parse_peer!(peer) do
    case String.split(peer, ":", parts: 2) do
      [host, port_str] ->
        case Integer.parse(port_str) do
          {port, ""} when port > 0 and port < 65_536 ->
            {host, port}

          _ ->
            raise ArgumentError, "Porta inválida em TCP_PEERS: #{peer}"
        end

      _ ->
        raise ArgumentError, "Peer inválido em TCP_PEERS: #{peer}. Use host:port"
    end
  end

  defp normalize_peers(peers) do
    Enum.map(peers, fn
      {host, port} when is_binary(host) and is_integer(port) -> {host, port}
      peer when is_binary(peer) -> parse_peer!(peer)
    end)
  end

  defp format_peer(host, port), do: "#{host}:#{port}"

  defp split_peer(peer) do
    [host, port] = String.split(peer, ":", parts: 2)
    {host, String.to_integer(port)}
  end

  defp ensure_line(message) do
    if String.ends_with?(message, "\n"), do: message, else: message <> "\n"
  end
end
