defmodule Sector.SensorIntegrationTest do
  use ExUnit.Case, async: false

  @passkey "08416EB34E46FD01C0E03B5E9B4AEACC06306F16D3E380559BBBAD8323C82A13"

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

  # Aguarda o TcpServer processar {:new_client} antes de enviar dados,
  # evitando a race condition onde o auth chega antes do socket estar em pending_auth.
  defp connect_and_auth(port, id) do
    {:ok, socket} =
      :gen_tcp.connect(~c"127.0.0.1", port, [:binary, packet: :line, active: false])

    Process.sleep(30)

    auth = JSON.encode!(%{"type" => "auth", "id" => id, "passkey" => @passkey}) <> "\n"
    :ok = :gen_tcp.send(socket, auth)
    socket
  end

  test "fluxo completo: sensor detecta problema, setor pede permissao, aloca drone e conclui" do
    peer_port = 6050
    node_port = 6051

    # Inicia o socket do "Peer" (simula outro setor que o TcpClient vai conectar)
    {:ok, listen_socket} =
      :gen_tcp.listen(peer_port, [:binary, packet: :line, active: false, reuseaddr: true])

    System.put_env("HOSTS", "127.0.0.1:#{peer_port}")

    {:ok, _pid} = Sector.Node.start_link(tcp_port: node_port)

    # Aceita a conexão de saída do TcpClient
    {:ok, peer_server_socket} = :gen_tcp.accept(listen_socket, 2000)

    # Consome o auth que o TcpClient envia automaticamente ao conectar
    assert {:ok, auth_data} = :gen_tcp.recv(peer_server_socket, 0, 2000)
    assert String.contains?(auth_data, "auth")

    # Conecta o "Peer" de volta ao TcpServer do Node e autentica
    peer_client_socket = connect_and_auth(node_port, "127.0.0.1:#{peer_port}")

    # Conecta o Sensor mockado e autentica
    sensor_socket = connect_and_auth(node_port, "sensor_007")

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

    # 2. Conecta o Drone mockado, autentica e fica IDLE
    drone_socket = connect_and_auth(node_port, "drone_resgate")

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

    # 4. Setor enfileira a req do sensor e manda um Request para o Peer
    assert {:ok, req_data} = :gen_tcp.recv(peer_server_socket, 0, 5000)
    req_msg = JSON.decode!(String.trim(req_data))
    assert req_msg["type"] == "request"
    assert req_msg["priority"] == 1

    # 5. Peer manda o Reply autorizando o Setor
    reply_msg = %{
      "type" => "reply",
      "from" => "127.0.0.1:#{peer_port}",
      "to" => req_msg["from"],
      "clock" => req_msg["clock"] + 1,
      "priority" => 0
    }

    :ok = :gen_tcp.send(peer_client_socket, JSON.encode!(reply_msg) <> "\n")

    # 6. Setor entra na SC e aloca o drone. Drone recebe a "Mission".
    assert {:ok, mission_data} = :gen_tcp.recv(drone_socket, 0, 5000)
    mission_msg = JSON.decode!(String.trim(mission_data))
    assert mission_msg["type"] == "mission"
    assert mission_msg["drone_id"] == "drone_resgate"

    # 7. Drone aceita a missão e envia o MissionAck
    ack_msg = %{
      "type" => "mission_ack",
      "drone_id" => "drone_resgate",
      "to" => mission_msg["from"]
    }

    :ok = :gen_tcp.send(drone_socket, JSON.encode!(ack_msg) <> "\n")

    Process.sleep(500)

    # 8. Setor deve ter saído da SC
    state_final = :sys.get_state(Sector.Node)
    assert state_final.in_critical_section? == false
    assert state_final.pending_mission_ack == nil

    mission_doing = Map.get(state_final.drones_doing_mission, "drone_resgate")
    assert mission_doing =~ "Incêndio na casa de máquinas"

    :gen_tcp.close(drone_socket)
    :gen_tcp.close(sensor_socket)
    :gen_tcp.close(peer_client_socket)
    :gen_tcp.close(peer_server_socket)
    :gen_tcp.close(listen_socket)
  end
end
