defmodule Drone.Worker do
  @moduledoc """
  Gerencia o estado do Drone (IDLE ou BUSY) e a execução de missões.

  - Ao aceitar uma missão (status IDLE), envia `MissionAck` de volta ao setor.
  - Ao rejeitar uma missão (status BUSY), envia `MissionReject` com o
    `mission_name` e `clock` originais para que o setor possa re-enfileirar
    sem perder o clock lógico.
  """

  use GenServer
  require Logger

  alias Core.Protocol.{DroneStatus, Mission, MissionAck, MissionReject}

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
    drone_id =
      Keyword.get(opts, :drone_id, System.get_env("DRONE_ID") || "drone_#{:rand.uniform(10000)}")

    state = %{
      drone_id: drone_id,
      status: "IDLE",
      mission_ref: nil,
      master_peer: nil
    }

    Logger.info("Drone iniciado com status #{state.status} (ID: #{state.drone_id})")
    IO.puts("=== [DRONE] Iniciado com status #{state.status} (ID: #{state.drone_id}) ===")

    # Dá um tempo para o TcpClient conectar antes de anunciar o status
    Process.send_after(self(), :broadcast_status, 2000)

    {:ok, state}
  end

  @impl true
  def handle_cast({:network_message, peer, line}, state) do
    case JSON.decode(line) do
      {:ok, map} ->
        process_network_map(map, peer, state)

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

  defp process_network_map(map, peer, state) do
    case Mission.from_map(map) do
      {:ok, %Mission{drone_id: target_id} = mission} ->
        if target_id == state.drone_id do
          handle_mission(peer, mission, state)
        else
          {:noreply, state}
        end

      _ ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:broadcast_status, state) do
    broadcast_status(state)
    Process.send_after(self(), :broadcast_status, 15_000)
    {:noreply, state}
  end

  @impl true
  def handle_info(:complete_mission, state) do
    Logger.info("Missão concluída! Voltando para IDLE.")
    IO.puts("=== [DRONE] Missão concluída! Voltando para IDLE. ===")

    new_state = %{state | status: "IDLE", mission_ref: nil, master_peer: nil}
    broadcast_status(new_state)

    {:noreply, new_state}
  end

  ## Internal Logic

  # Drone IDLE: aceita a missão e envia MissionAck ao setor de origem.
  defp handle_mission(peer, %Mission{from: from}, %{status: "IDLE"} = state) do
    duration = random_duration_ms()
    Logger.info("Recebeu missão do nó #{peer}! Duração: #{duration}ms")
    IO.puts("=== [DRONE] Recebeu missão do nó #{peer}! Trabalhando por #{duration}ms... ===")

    ref = Process.send_after(self(), :complete_mission, duration)
    new_state = %{state | status: "BUSY", mission_ref: ref, master_peer: peer}

    broadcast_status(new_state)

    # Envia ACK para o setor que enviou a missão
    ack = %MissionAck{
      type: :mission_ack,
      drone_id: state.drone_id,
      to: from
    }

    send_to_sector(from, ack)

    IO.puts("=== [DRONE] MissionAck enviado para #{from} ===")
    Logger.info("[DRONE] MissionAck enviado para #{from}")

    {:noreply, new_state}
  end

  # Drone BUSY: rejeita a missão e ecoa mission_name + clock para o setor poder re-enfileirar.
  defp handle_mission(
         _peer,
         %Mission{from: from, mission_name: mission_name, clock: clock},
         %{status: "BUSY"} = state
       ) do
    Logger.warning(
      "[DRONE] Recebeu pedido de missão '#{mission_name}' (clock=#{clock}), mas já está BUSY. Enviando MissionReject para #{from}."
    )

    IO.puts(
      "=== [DRONE] BUSY — enviando MissionReject para #{from} (missão: #{mission_name}, clock: #{clock}) ==="
    )

    reject = %MissionReject{
      type: :mission_reject,
      drone_id: state.drone_id,
      to: from,
      mission_name: mission_name,
      clock: clock
    }

    send_to_sector(from, reject)

    {:noreply, state}
  end

  # Fallback: status desconhecido
  defp handle_mission(_peer, _mission, state) do
    Logger.warning("[DRONE] handle_mission: status inesperado '#{state.status}', ignorando.")
    {:noreply, state}
  end

  defp send_to_sector(address, struct) do
    msg = JSON.encode!(struct) <> "\n"

    if Code.ensure_loaded?(Drone.TcpClient) and Process.whereis(Drone.TcpClient) do
      Drone.TcpClient.send_to(address, msg)
    else
      Logger.error("[DRONE] TcpClient não disponível para enviar para #{address}")
    end
  end

  defp broadcast_status(state) do
    msg_struct = %DroneStatus{
      type: :drone_status,
      drone_id: state.drone_id,
      status: state.status
    }

    msg = JSON.encode!(msg_struct) <> "\n"

    if Code.ensure_loaded?(Drone.TcpClient) and Process.whereis(Drone.TcpClient) do
      Drone.TcpClient.broadcast(msg)
    end
  end

  defp random_duration_ms do
    30_000
  end
end
