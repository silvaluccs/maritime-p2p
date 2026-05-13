defmodule Sensors.WorkerTest do
  use ExUnit.Case, async: false

  setup do
    if pid = Process.whereis(Sensors.Worker) do
      try do
        GenServer.stop(pid)
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end

  test "sensor conecta ao setor, envia status e gera requisicoes" do
    port = 6010

    System.put_env("HOST", "127.0.0.1:#{port}")

    {:ok, listen_socket} =
      :gen_tcp.listen(port, [:binary, packet: :line, active: false, reuseaddr: true])

    {:ok, pid} = Sensors.Worker.start_link(sensor_id: "test_sensor_1", name: :test_sensor_1)

    {:ok, sector_socket} = :gen_tcp.accept(listen_socket, 2000)

    # 1. O sensor envia auth antes de qualquer outra mensagem — consome aqui
    assert {:ok, auth_data} = :gen_tcp.recv(sector_socket, 0, 1000)
    auth_msg = JSON.decode!(String.trim(auth_data))
    assert auth_msg["type"] == "auth"

    # 2. Agora verifica o SensorStatus
    assert {:ok, data_status} = :gen_tcp.recv(sector_socket, 0, 1000)
    status_msg = JSON.decode!(String.trim(data_status))
    assert status_msg["type"] == "sensor_status"
    assert is_binary(status_msg["sensor_id"])
    assert status_msg["status"] == "CONNECTED"

    # 3. Força o Sensor a gerar uma requisição sem esperar o timer
    send(pid, :generate_request)

    assert {:ok, data_req} = :gen_tcp.recv(sector_socket, 0, 1000)
    req_msg = JSON.decode!(String.trim(data_req))
    assert req_msg["type"] == "sensor_request"
    assert req_msg["sensor_id"] == "test_sensor_1"
    assert req_msg["priority"] in [0, 1]
    assert is_binary(req_msg["reason"])
    assert String.length(req_msg["reason"]) > 0

    :gen_tcp.close(sector_socket)
    :gen_tcp.close(listen_socket)
  end

  test "sensor tenta reconectar quando a conexao cai" do
    port = 6011

    System.put_env("HOST", "127.0.0.1:#{port}")

    {:ok, listen_socket} =
      :gen_tcp.listen(port, [:binary, packet: :line, active: false, reuseaddr: true])

    {:ok, pid} = Sensors.Worker.start_link(sensor_id: "test_sensor_2", name: :test_sensor_2)

    {:ok, sector_socket} = :gen_tcp.accept(listen_socket, 2000)

    # Consome o auth inicial (e opcionalmente o sensor_status)
    {:ok, _} = :gen_tcp.recv(sector_socket, 0, 1000)

    :gen_tcp.close(sector_socket)
    :gen_tcp.close(listen_socket)

    Process.sleep(100)

    state = :sys.get_state(pid)
    assert state.socket == nil
  end
end
