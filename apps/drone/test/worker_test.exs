defmodule Drone.WorkerTest do
  use ExUnit.Case, async: false
  alias Core.Protocol.Mission

  setup do
    if pid = Process.whereis(Drone.Worker), do: GenServer.stop(pid)
    :ok
  end

  test "quando o drone recebe missao e esta IDLE ele fica BUSY (mock state)" do
    {:ok, _pid} = Drone.Worker.start_link(drone_id: "test_drone_idle")
    peer = "127.0.0.1:5001"

    mission = %Mission{type: :mission, drone_id: "test_drone_idle", from: peer}
    line = JSON.encode!(mission)

    Drone.Worker.handle_network_message(peer, line)
    Process.sleep(50)

    state = :sys.get_state(Drone.Worker)
    assert state.status == "BUSY"
    assert state.master_peer == peer
    assert state.mission_ref != nil
  end

  test "quando o drone recebe missao mas ja esta BUSY ele envia reject" do
    {:ok, _pid} = Drone.Worker.start_link(drone_id: "test_drone_busy")
    peer1 = "127.0.0.1:5001"
    peer2 = "127.0.0.1:5002"

    mission1 = %Mission{type: :mission, drone_id: "test_drone_busy", from: peer1}
    Drone.Worker.handle_network_message(peer1, JSON.encode!(mission1))
    Process.sleep(50)

    state_after_first = :sys.get_state(Drone.Worker)
    assert state_after_first.status == "BUSY"

    # Envia segunda missao
    mission2 = %Mission{
      type: :mission,
      drone_id: "test_drone_busy",
      from: peer2,
      mission_name: "m2",
      clock: 2
    }

    Drone.Worker.handle_network_message(peer2, JSON.encode!(mission2))
    Process.sleep(50)

    # O estado não deve ter mudado para o peer2
    state_after_second = :sys.get_state(Drone.Worker)
    assert state_after_second.status == "BUSY"
    assert state_after_second.master_peer == peer1
  end

  test "quando o sector cair o drone deve parar a missão e informar que esta livre" do
    # Inicia o Drone
    {:ok, _pid} = Drone.Worker.start_link(drone_id: "test_drone_1")

    # Dá tempo de iniciar
    Process.sleep(100)

    # Simula recebimento de uma missão vinda de um peer (setor)
    peer = "127.0.0.1:5000"
    mission = %Mission{type: :mission, drone_id: "test_drone_1", from: peer}
    line = JSON.encode!(mission)

    Drone.Worker.handle_network_message(peer, line)

    # O drone deve estar ocupado
    Process.sleep(100)
    state = :sys.get_state(Drone.Worker)
    assert state.status == "BUSY"
    assert state.master_peer == peer

    # Simula a desconexão do setor
    Drone.Worker.handle_disconnect(peer)

    # O drone deve voltar para IDLE
    Process.sleep(100)
    state_after = :sys.get_state(Drone.Worker)
    assert state_after.status == "IDLE"
    assert state_after.master_peer == nil
    assert state_after.mission_ref == nil
  end
end
