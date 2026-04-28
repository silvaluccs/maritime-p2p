defmodule Sector.TcpClient do
  @moduledoc """
  GenServer responsável por gerenciar a conexão TCP com outros nós do setor.
  """
  use GenServer
  require Logger

  @reconnect_ms 5_000

  def start_link(args \\ []) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  def connected_hosts do
    GenServer.call(__MODULE__, :connected_hosts)
  end

  def broadcast(message) do
    GenServer.call(__MODULE__, {:broadcast, message})
  end

  def send_to(address, message) do
    GenServer.call(__MODULE__, {:send_to, address, message})
  end

  @impl true
  def init(_opts) do
    hosts = get_hosts_from_env()

    state = %{
      reconnect_timer: @reconnect_ms,
      sockets: %{},
      hosts: hosts
    }

    send(self(), :connect_hosts)

    {:ok, state}
  end

  @impl true
  def handle_call({:broadcast, message}, _from, state) do
    payload = message |> JSON.encode!() |> ensure_line()

    results_sends =
      Enum.map(state.sockets, fn {address, socket} ->
        send_result = :gen_tcp.send(socket, payload)

        if send_result != :ok,
          do: Logger.error("Falha ao enviar mensagem para #{address}: #{inspect(send_result)}")

        {address, send_result}
      end)

    {:reply, results_sends, state}
  end

  @impl true
  def handle_call({:send_to, address, message}, _from, state) do
    payload = message |> JSON.encode!() |> ensure_line()

    case Map.fetch(state.sockets, address) do
      {:ok, socket} ->
        case :gen_tcp.send(socket, payload) do
          :ok ->
            {:reply, :ok, state}

          {:error, reason} ->
            Logger.error("Falha ao enviar mensagem para #{address}: #{reason}")
            {:reply, {:error, reason}, state}
        end

      :error ->
        Logger.warning("Endereço não encontrado para envio: #{address}")
        {:reply, {:error, :not_connected}, state}
    end
  end

  @impl true
  def handle_call(:connected_hosts, _from, state) do
    hosts_connected =
      state.sockets
      |> Enum.map(fn {address, socket} -> %{address: address, socket: socket} end)

    {:reply, hosts_connected, state}
  end

  @impl true
  def handle_info(:connect_hosts, state) do
    new_state = Enum.reduce(state.hosts, state, &maybe_connect_host/2)
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:reconnect, {address, host, port}}, state) do
    if Map.has_key?(state.sockets, address) do
      {:noreply, state}
    else
      {:noreply, connect(address, host, port, state)}
    end
  end

  @impl true
  def handle_info({:tcp_closed, socket}, state) do
    remove_socket_and_try_reconnect(socket, state)
  end

  @impl true
  def handle_info({:tcp_error, socket, reason}, state) do
    Logger.error("Erro na conexão TCP: #{reason}")
    remove_socket_and_try_reconnect(socket, state)
  end

  defp remove_socket_and_try_reconnect(socket, state) do
    case find_address_by_socket(socket, state.sockets) do
      nil ->
        Logger.warning("Conexão fechada por socket desconhecido")
        {:noreply, state}

      {address, _socket} ->
        Logger.info("Conexão fechada: #{address}")
        new_state = remove_socket(socket, state)
        {:noreply, schedule_reconnect(new_state, address)}
    end
  end

  defp remove_socket(socket, state) do
    case find_address_by_socket(socket, state.sockets) do
      nil ->
        Logger.warning("Conexão fechada por socket desconhecido")
        state

      {address, socket} ->
        Logger.info("Conexão fechada: #{address}")
        new_state = state |> Map.update!(:sockets, &Map.delete(&1, address))
        :gen_tcp.close(socket)
        new_state
    end
  end

  defp maybe_connect_host({ip, port}, state) do
    address = "#{ip}:#{port}"

    if Map.has_key?(state.sockets, address) do
      state
    else
      connect(address, ip, port, state)
    end
  end

  defp connect(address, host, port, state) do
    case :gen_tcp.connect(
           String.to_charlist(host),
           port,
           [:binary, packet: :line, active: :once],
           3_000
         ) do
      {:ok, socket} ->
        Logger.info("Conectado a #{inspect(address)}")

        state
        |> Map.update!(:sockets, &Map.put(&1, address, socket))

      {:error, reason} ->
        Logger.warning("Falha ao conectar a #{host}:#{port} - #{inspect(reason)}")
        schedule_reconnect(state, {address, host, port})
    end
  end

  defp schedule_reconnect(state, {address, host, port}) do
    Process.send_after(self(), {:reconnect, {address, host, port}}, state.reconnect_timer)
    state
  end

  defp schedule_reconnect(state, address) do
    [host, port_str] = String.split(address, ":", parts: 2)
    schedule_reconnect(state, {address, host, String.to_integer(port_str)})
  end

  defp find_address_by_socket(socket, sockets) do
    sockets
    |> Enum.find(fn {_address, s} -> s == socket end)
  end

  defp get_hosts_from_env do
    get_hosts()
    |> Enum.map(&parse_host/1)
    |> Enum.map(fn
      {:ok, host} -> host
      {:error, _} -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp ensure_line(message) do
    if String.ends_with?(message, "\n"), do: message, else: message <> "\n"
  end

  defp get_hosts do
    System.get_env("HOSTS", "")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_host(host) do
    case String.split(host, ":") do
      [ip, port_str] ->
        case Integer.parse(port_str) do
          {port, ""} when port in 1..65_535 ->
            {:ok, {ip, port}}

          _ ->
            Logger.warning("Porta inválida ignorada: #{host}")
            {:error, :invalid_port}
        end

      _ ->
        Logger.warning("Formato de host inválido ignorado: #{host}")
        {:error, :invalid_host_format}
    end
  end
end
