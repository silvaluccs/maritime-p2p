defmodule Sensors.WorkerTest do
  use ExUnit.Case, async: false

  setup do
    if pid = Process.whereis(Sensors.Worker), do: GenServer.stop(pid)
    :ok
  end

  test "sensor conecta ao setor, envia status e gera requisicoes" do
    port = 6010
    System.put_env("HOST", "127.0.0.1:#{port}")

    # Inicia um servidor TCP dummy que vai agir como o Setor
    {:ok, listen_socket} =
      :gen_tcp.listen(port, [:binary, packet: :line, active: false, reuseaddr: true])

    # Inicia o worker do Sensor
    {:ok, pid} = Sensors.Worker.start_link(sensor_id: "test_sensor_1", name: :test_sensor_1)

    # Aceita a conexão do Sensor
    {:ok, sector_socket} = :gen_tcp.accept(listen_socket, 2000)

    # 1. Verifica se o primeiro pacote recebido é o SensorStatus
    assert {:ok, data_status} = :gen_tcp.recv(sector_socket, 0, 1000)
    status_msg = JSON.decode!(String.trim(data_status))

    assert status_msg["type"] == "sensor_status"
    # Pode haver conflitos com Sensor ID se já existir na supervisor,
    # mas garantimos que a key existe.
    assert is_binary(status_msg["sensor_id"])
    assert status_msg["status"] == "CONNECTED"

    # 2. Força o Sensor a gerar uma requisição sem ter que esperar 10 segundos
    send(pid, :generate_request)

    # Verifica se o pacote de SensorRequest chegou com motivo e prioridade
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

    # Consome o status inicial
    {:ok, _} = :gen_tcp.recv(sector_socket, 0, 1000)

    # Fecha a conexão do lado do "setor"
    :gen_tcp.close(sector_socket)
    :gen_tcp.close(listen_socket)

    # Aguarda o sensor processar a queda
    Process.sleep(100)

    # Verifica o estado do sensor, deve estar com socket nil tentando reconectar
    state = :sys.get_state(pid)
    assert state.socket == nil
  end
end
