defmodule Sector.SensorIntegrationTest do
  use ExUnit.Case, async: false

  setup do
    Enum.each([Sector.Node, Sector.TcpServer, Sector.TcpClient], fn mod ->
      if pid = Process.whereis(mod) do
        try do
          GenServer.stop(pid)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    System.delete_env("HOSTS")
    :ok
  end

  test "fluxo completo: sensor detecta problema, setor pede permissao, aloca drone e conclui" do
    peer_port = 6050
    node_port = 6051

    # Inicia o socket do "Peer"
    {:ok, listen_socket} =
      :gen_tcp.listen(peer_port, [:binary, packet: :line, active: false, reuseaddr: true])

    System.put_env("HOSTS", "127.0.0.1:#{peer_port}")

    # Inicia o Node
    {:ok, _pid} = Sector.Node.start_link(tcp_port: node_port)

    # Conecta o Peer de fato
    {:ok, peer_server_socket} = :gen_tcp.accept(listen_socket, 2000)

    {:ok, peer_client_socket} =
      :gen_tcp.connect(~c"127.0.0.1", node_port, [:binary, packet: :line, active: false])

    # Conecta o Sensor mockado
    {:ok, sensor_socket} =
      :gen_tcp.connect(~c"127.0.0.1", node_port, [:binary, packet: :line, active: false])

    # 1. Envia SensorStatus para registrar o sensor no setor
    sensor_status = %{
      "type" => "sensor_status",
      "sensor_id" => "sensor_007",
      "status" => "CONNECTED"
    }

    :ok = :gen_tcp.send(sensor_socket, JSON.encode!(sensor_status) <> "\n")

    Process.sleep(100)
    state = :sys.get_state(Sector.Node)
    assert MapSet.member?(state.connected_sensors, "sensor_007")

    # 2. Conecta o Drone mockado e fica IDLE
    {:ok, drone_socket} =
      :gen_tcp.connect(~c"127.0.0.1", node_port, [:binary, packet: :line, active: false])

    drone_status = %{"type" => "drone_status", "drone_id" => "drone_resgate", "status" => "IDLE"}
    :ok = :gen_tcp.send(drone_socket, JSON.encode!(drone_status) <> "\n")

    Process.sleep(100)
    state = :sys.get_state(Sector.Node)
    assert MapSet.member?(state.available_drones, "drone_resgate")

    # 3. Sensor gera a requisição (Risco Crítico)
    sensor_req = %{
      "type" => "sensor_request",
      "sensor_id" => "sensor_007",
      "priority" => 1,
      "reason" => "Incêndio na casa de máquinas"
    }

    :ok = :gen_tcp.send(sensor_socket, JSON.encode!(sensor_req) <> "\n")

    # 4. Setor vai processar a req do sensor, enfileirar e mandar um "Request" pro Peer
    assert {:ok, req_data} = :gen_tcp.recv(peer_server_socket, 0, 5000)
    req_msg = JSON.decode!(String.trim(req_data))
    assert req_msg["type"] == "request"
    assert req_msg["priority"] == 1

    # 5. Peer manda o Reply de volta autorizando o Setor
    reply_msg = %{
      "type" => "reply",
      "from" => "127.0.0.1:#{peer_port}",
      "to" => req_msg["from"],
      "clock" => req_msg["clock"] + 1,
      "priority" => 0
    }

    :ok = :gen_tcp.send(peer_client_socket, JSON.encode!(reply_msg) <> "\n")

    # 6. Setor entra na Seção Crítica e aloca o drone disponível! O Drone deve receber a "Mission"
    assert {:ok, mission_data} = :gen_tcp.recv(drone_socket, 0, 5000)
    mission_msg = JSON.decode!(String.trim(mission_data))
    assert mission_msg["type"] == "mission"
    assert mission_msg["drone_id"] == "drone_resgate"

    # 7. Drone aceita a missão e envia o MissionAck para concluir a SC do Setor
    ack_msg = %{
      "type" => "mission_ack",
      "drone_id" => "drone_resgate",
      "to" => mission_msg["from"]
    }

    :ok = :gen_tcp.send(drone_socket, JSON.encode!(ack_msg) <> "\n")

    Process.sleep(500)

    # 8. Valida que o setor saiu da Seção Crítica e a missão (agora rodando no drone) não trava mais a rede
    state_final = :sys.get_state(Sector.Node)
    assert state_final.in_critical_section? == false
    assert state_final.pending_mission_ack == nil

    # Confere se a missão do sensor foi de fato para a lista de 'fazendo'
    # The node prefixes the sensor ID as 'SENSOR sensor_007' but the ID might be something else
    # The ID generated in the code is the counter (ex: SENSOR 1). We just need to check for the reason.
    mission_doing = Map.get(state_final.drones_doing_mission, "drone_resgate")
    assert mission_doing =~ "Incêndio na casa de máquinas"

    :gen_tcp.close(drone_socket)
    :gen_tcp.close(sensor_socket)
    :gen_tcp.close(peer_client_socket)
    :gen_tcp.close(peer_server_socket)
    :gen_tcp.close(listen_socket)
  end
end
