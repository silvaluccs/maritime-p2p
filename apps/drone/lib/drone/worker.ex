defmodule Drone.Worker do
  @moduledoc """
  Gerencia o estado do Drone (IDLE ou BUSY) e a execução de missões.
  """

  use GenServer
  require Logger

  alias Core.Protocol.{DroneStatus, Mission}

  @min_mission_ms 60_000
  @max_mission_ms 180_000

  ## Public API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Chamado pelo TcpClient quando o Drone recebe uma mensagem da rede.
  """
  def handle_network_message(peer, line) do
    GenServer.cast(__MODULE__, {:network_message, peer, String.trim(line)})
  end

  def handle_disconnect(peer) do
    GenServer.cast(__MODULE__, {:disconnect, peer})
  end

  ## GenServer callbacks

  @impl true
  def init(opts) do
    # Assuming UUIDv7 is available, if not we'll use standard random or a passed in ID
    drone_id =
      Keyword.get(opts, :drone_id, System.get_env("DRONE_ID") || "drone_#{:rand.uniform(10000)}")

    state = %{
      drone_id: drone_id,
      status: "IDLE",
      mission_ref: nil,
      master_peer: nil
    }

    Logger.info("Drone iniciado com status #{state.status} (ID: #{state.drone_id})")

    # Dá um tempo para o TcpClient conectar antes de anunciar o status
    Process.send_after(self(), :broadcast_status, 2000)

    {:ok, state}
  end

  @impl true
  def handle_cast({:network_message, peer, line}, state) do
    case JSON.decode(line) do
      {:ok, map} ->
        case Mission.from_map(map) do
          {:ok, %Mission{drone_id: target_id}} ->
            if target_id == state.drone_id do
              handle_mission(peer, state)
            else
              {:noreply, state}
            end

          _ ->
            # Message may be something else, ignore
            {:noreply, state}
        end

      {:error, _} ->
        Logger.warning("Falha ao decodificar JSON recebido do peer #{peer}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:disconnect, peer}, state) do
    if state.status == "BUSY" and state.master_peer == peer do
      Logger.warning("O nó mestre #{peer} caiu! Abortando missão e voltando para IDLE.")

      if state.mission_ref, do: Process.cancel_timer(state.mission_ref)

      new_state = %{state | status: "IDLE", mission_ref: nil, master_peer: nil}
      broadcast_status(new_state)
      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(:broadcast_status, state) do
    broadcast_status(state)

    # Reanuncia o status periodicamente para nós que possam ter reconectado
    Process.send_after(self(), :broadcast_status, 15_000)

    {:noreply, state}
  end

  @impl true
  def handle_info(:complete_mission, state) do
    Logger.info("Missão concluída! Voltando para IDLE.")

    new_state = %{state | status: "IDLE", mission_ref: nil, master_peer: nil}
    broadcast_status(new_state)

    {:noreply, new_state}
  end

  ## Internal Logic

  defp handle_mission(peer, state) do
    if state.status == "IDLE" do
      duration = random_duration_ms()
      Logger.info("Recebeu missão do nó #{peer}! Duração: #{duration}ms")

      ref = Process.send_after(self(), :complete_mission, duration)
      new_state = %{state | status: "BUSY", mission_ref: ref, master_peer: peer}

      broadcast_status(new_state)
      {:noreply, new_state}
    else
      Logger.warning("Recebeu pedido de missão, mas já está BUSY.")
      {:noreply, state}
    end
  end

  defp broadcast_status(state) do
    # Dispara para todos os nós conectados qual é o estado atual do Drone
    msg_struct = %DroneStatus{
      type: :drone_status,
      drone_id: state.drone_id,
      status: state.status
    }

    msg = JSON.encode!(msg_struct) <> "\n"

    if Code.ensure_loaded?(Drone.TcpClient) do
      Drone.TcpClient.broadcast(msg)
    end
  end

  defp random_duration_ms do
    :rand.uniform(@max_mission_ms - @min_mission_ms + 1) + (@min_mission_ms - 1)
  end
end
