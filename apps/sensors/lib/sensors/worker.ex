defmodule Sensors.Worker do
  @moduledoc """
  Worker responsável por gerenciar a conexão de um sensor com o setor.
  Ele se conecta ao setor, registra-se e gerencia as requisições de detecção.
  Envia requisições de detecção para o setor e recebe respostas.
  """

  use GenServer
  require Logger

  alias Core.Env

  @reconnect_time 5000
  @time_for_generate_request 60_000

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    host = Env.get_hosts_from_env("HOST")

    sensor_id = opts[:sensor_id] || UUIDv7.generate()

    state = %{sensor_id: sensor_id, host: host, socket: nil}

    send(self(), :connect)

    {:ok, state}
  end

  @impl true
  def handle_info(:connect, state) do
    host_to_connect =
      if is_list(state.host) do
        List.first(state.host)
      else
        state.host
      end

    case must_connect_to_host(host_to_connect) do
      {:ok, socket} ->
        auth_msg = %Core.Protocol.Auth{
          type: :auth,
          id: state.sensor_id,
          passkey: Core.Auth.get_hashed_passkey()
        }

        :gen_tcp.send(socket, JSON.encode!(auth_msg) <> "\n")

        status_msg = %Core.Protocol.SensorStatus{
          type: :sensor_status,
          sensor_id: state.sensor_id,
          status: "CONNECTED"
        }

        :gen_tcp.send(socket, JSON.encode!(status_msg) <> "\n")

        IO.puts("=== [SENSOR] Conectado ao Setor. Registrado com ID #{state.sensor_id}. ===")

        Process.send_after(self(), :generate_request, @time_for_generate_request)

        {:noreply, %{state | socket: socket}}

      {:error, _reason} ->
        {:noreply, try_connect_again(state)}
    end
  end

  @impl true
  def handle_info(:generate_request, %{socket: nil} = state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(:generate_request, state) do
    # 20% de chance para Prio 1 e 80% para Prio 0
    priority = if :rand.uniform() > 0.8, do: 1, else: 0
    reason = Sensors.Reasons.get_random()

    request_msg = %Core.Protocol.SensorRequest{
      type: :sensor_request,
      sensor_id: state.sensor_id,
      priority: priority,
      reason: reason
    }

    IO.puts("=== [SENSOR] Gerando Requisição (Prio: #{priority}) Motivo: #{reason} ===")

    case :gen_tcp.send(state.socket, JSON.encode!(request_msg) <> "\n") do
      :ok ->
        Logger.info("Requisição enviada: #{reason}")

      {:error, reason_tcp} ->
        Logger.error("Falha ao enviar requisição do sensor: #{inspect(reason_tcp)}")
    end

    next_time = Enum.random(5_000..15_000)
    Process.send_after(self(), :generate_request, next_time)

    {:noreply, state}
  end

  @impl true
  def handle_info({:tcp_closed, _socket}, state) do
    Logger.warning("Conexão com o setor perdida. Tentando reconectar...")
    {:noreply, try_connect_again(%{state | socket: nil})}
  end

  @impl true
  def handle_info({:tcp_error, _socket, reason}, state) do
    Logger.warning("Erro na conexão com o setor: #{inspect(reason)}. Tentando reconectar...")
    {:noreply, try_connect_again(%{state | socket: nil})}
  end

  @impl true
  def handle_info({:tcp, _socket, _data}, state) do
    {:noreply, state}
  end

  defp try_connect_again(state) do
    Logger.info("Retrying connection in #{inspect(@reconnect_time)}ms")
    Process.send_after(self(), :connect, @reconnect_time)
    state
  end

  defp must_connect_to_host(nil) do
    Logger.error("Variável HOST não configurada. Não é possível conectar ao setor.")
    {:error, :no_host}
  end

  defp must_connect_to_host({ip, port}) do
    Logger.info("Connecting to #{inspect(ip)}:#{inspect(port)}")

    case :gen_tcp.connect(
           String.to_charlist(ip),
           port,
           [:binary, packet: :line, active: true],
           3_000
         ) do
      {:ok, socket} ->
        Logger.info("Connected")
        {:ok, socket}

      {:error, reason} ->
        Logger.error("Failed to connect to #{inspect(ip)}:#{inspect(port)}: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
