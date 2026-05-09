defmodule Sector.NodeAlgoritmTest do
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

  test "fluxo completo de exclusao mutua: envia request, recebe reply e entra na secao critica" do
    peer_port = 5050
    node_port = 5051

    {:ok, listen_socket} =
      :gen_tcp.listen(peer_port, [:binary, packet: :line, active: false, reuseaddr: true])

    System.put_env("HOSTS", "127.0.0.1:#{peer_port}")

    {:ok, _pid} = Sector.Node.start_link(tcp_port: node_port)

    {:ok, peer_server_socket} = :gen_tcp.accept(listen_socket, 2000)

    {:ok, peer_client_socket} =
      :gen_tcp.connect(~c"127.0.0.1", node_port, [:binary, packet: :line, active: false])

    # Dispara manualmente a solicitação, já que o timer automático não existe mais
    send(Sector.Node, :try_critical_section)

    assert {:ok, data} = :gen_tcp.recv(peer_server_socket, 0, 7000)

    # verifica se a mensagem recebida é de fato um request válido
    assert %{"type" => "request", "clock" => req_clock, "from" => node_id} =
             JSON.decode!(String.trim(data))

    # Nós (Node B) enviamos o nosso Request PRIMEIRO (clock maior = menor prioridade de Lamport)!
    peer_request_msg = %{
      "type" => "request",
      "from" => "127.0.0.1:#{peer_port}",
      "to" => "broadcast",
      "clock" => req_clock + 10,
      "priority" => 0
    }

    :ok = :gen_tcp.send(peer_client_socket, JSON.encode!(peer_request_msg) <> "\n")

    # AGORA enviamos o "Reply" autorizando a entrada do Node A.
    reply_msg = %{
      "type" => "reply",
      "from" => "127.0.0.1:#{peer_port}",
      "to" => node_id,
      "clock" => req_clock + 1,
      "priority" => 0
    }

    :ok = :gen_tcp.send(peer_client_socket, JSON.encode!(reply_msg) <> "\n")

    # O Node A vai entrar na seção crítica e aguardar um drone disponível.
    # Simulamos um drone conectando e enviando "drone_status" = "IDLE".
    drone_socket =
      case :gen_tcp.connect(~c"127.0.0.1", node_port, [:binary, packet: :line, active: false]) do
        {:ok, sock} -> sock
        _ -> nil
      end

    drone_status_msg = %{
      "type" => "drone_status",
      "drone_id" => "test_drone",
      "status" => "IDLE"
    }

    :ok = :gen_tcp.send(drone_socket, JSON.encode!(drone_status_msg) <> "\n")

    # Após o drone ficar disponível, o nó o alocará e sairá da seção crítica,
    # desengavetando nosso pedido e nos mandando o "Reply".
    #
    # Porém, agora com a lógica de ACK, precisamos que o drone envie um MissionAck
    # para que a seção crítica de fato termine e libere o Reply.

    # 1. Drone recebe a "Mission" no TCP (precisamos ler o socket para tirar do buffer, opcional)
    # 2. Drone responde com MissionAck
    mission_ack_msg = %{
      "type" => "mission_ack",
      "drone_id" => "test_drone",
      "to" => node_id
    }

    # Adicionando um pequeno delay para ele poder ter feito a alocação internamente
    Process.sleep(500)
    :ok = :gen_tcp.send(drone_socket, JSON.encode!(mission_ack_msg) <> "\n")

    assert {:ok, reply_data} = :gen_tcp.recv(peer_server_socket, 0, 15_000)

    assert %{"type" => "reply", "from" => ^node_id} = JSON.decode!(String.trim(reply_data))

    # Limpeza dos Sockets de teste
    if drone_socket, do: :gen_tcp.close(drone_socket)
    :gen_tcp.close(peer_client_socket)
    :gen_tcp.close(peer_server_socket)
    :gen_tcp.close(listen_socket)
  end

  test "reenvia request para peer que conecta tardiamente" do
    node_port = 5052
    peer_port = 5053

    System.put_env("HOSTS", "127.0.0.1:#{peer_port}")

    {:ok, _pid} = Sector.Node.start_link(tcp_port: node_port)

    # Dispara a solicitação ANTES do peer conectar
    send(Sector.Node, :try_critical_section)

    {:ok, listen_socket} =
      :gen_tcp.listen(peer_port, [:binary, packet: :line, active: false, reuseaddr: true])

    {:ok, peer_server_socket} = :gen_tcp.accept(listen_socket, 2000)

    # Devemos receber o Request re-enviado por causa da conexão tardia
    assert {:ok, data} = :gen_tcp.recv(peer_server_socket, 0, 5000)
    assert %{"type" => "request"} = JSON.decode!(String.trim(data))

    :gen_tcp.close(peer_server_socket)
    :gen_tcp.close(listen_socket)
  end

  test "se o drone cair durante missao a requisicao eh reenfileirada com prioridade 2" do
    node_port = 5056

    {:ok, _pid} = Sector.Node.start_link(tcp_port: node_port)

    # Dispara a solicitação de CS
    send(Sector.Node, :try_critical_section)

    # Como ele é o único nó (HOSTS não definido), ele entra na SC rápido, mas espera o drone.
    Process.sleep(500)
    state = :sys.get_state(Sector.Node)
    assert state.in_critical_section? == true
    assert state.waiting_for_drone? == true

    # Nome da missão que está sendo processada
    mission_name = state.request_for_process

    # Conecta o "drone"
    {:ok, drone_socket} =
      :gen_tcp.connect(~c"127.0.0.1", node_port, [:binary, packet: :line, active: false])

    drone_status_msg = %{
      "type" => "drone_status",
      "drone_id" => "crashing_drone",
      "status" => "IDLE"
    }

    # Informa que está IDLE e pronto para missão
    :ok = :gen_tcp.send(drone_socket, JSON.encode!(drone_status_msg) <> "\n")

    # Espera que o Node receba e aloque. Com a lógica de ACK, ele NÃO sai da CS ainda.
    Process.sleep(500)

    state_after_alloc = :sys.get_state(Sector.Node)
    # in_critical_section? agora deve ser true, pois aguarda MissionAck
    assert state_after_alloc.in_critical_section? == true
    assert state_after_alloc.pending_mission_ack != nil
    assert Map.has_key?(state_after_alloc.drones_doing_mission, "crashing_drone")

    # Agora o drone cai (fecha o socket) antes de mandar o MissionAck (ou durante a missão)
    :gen_tcp.close(drone_socket)

    # Aguarda processar o TCP closed
    Process.sleep(500)

    state_after_crash = :sys.get_state(Sector.Node)
    assert not Map.has_key?(state_after_crash.drones_doing_mission, "crashing_drone")

    # A requisição deve estar de volta na fila com prioridade 2 (ou estar sendo processada de novo)
    # Se ele tentar processar de novo imediatamente e entrar na SC, o request_for_process será o mission_name
    found_in_queue =
      Enum.find(state_after_crash.request_queue, fn {priority, name, _ts, _status} ->
        name == mission_name and priority == 2
      end)

    is_processing_again =
      state_after_crash.in_critical_section? and
        state_after_crash.request_for_process == mission_name

    assert found_in_queue != nil or is_processing_again
  end

  test "quando o drone envia MissionReject a missao volta para a fila com prioridade" do
    node_port = 5057

    {:ok, _pid} = Sector.Node.start_link(tcp_port: node_port)

    # Dispara a solicitação de CS
    send(Sector.Node, :try_critical_section)

    Process.sleep(500)
    state = :sys.get_state(Sector.Node)
    assert state.in_critical_section? == true

    mission_name = state.request_for_process

    # Conecta um drone e o torna IDLE (para o Node tentar alocar)
    {:ok, drone_socket} =
      :gen_tcp.connect(~c"127.0.0.1", node_port, [:binary, packet: :line, active: false])

    drone_status_msg = %{
      "type" => "drone_status",
      "drone_id" => "rejecting_drone",
      "status" => "IDLE"
    }

    :ok = :gen_tcp.send(drone_socket, JSON.encode!(drone_status_msg) <> "\n")

    Process.sleep(500)

    # Verifica se ele alocou e está aguardando o ACK
    state_after_alloc = :sys.get_state(Sector.Node)
    assert state_after_alloc.in_critical_section? == true
    assert state_after_alloc.pending_mission_ack != nil

    # Simula o drone enviando um REJECT (porque ele pode ter ficado ocupado de outra fonte, race condition)
    mission_reject_msg = %{
      "type" => "mission_reject",
      "drone_id" => "rejecting_drone",
      "to" => state.node_id,
      "mission_name" => mission_name,
      "clock" => state.clock
    }

    :ok = :gen_tcp.send(drone_socket, JSON.encode!(mission_reject_msg) <> "\n")
    Process.sleep(500)

    # Após o reject, o setor deve ter saído da seção crítica e a missão deve ter voltado para a fila
    state_after_reject = :sys.get_state(Sector.Node)
    assert state_after_reject.pending_mission_ack == nil

    # Ele pode já ter tentado entrar de novo (dependendo do timer do GenServer), mas o ponto é
    # que ele saiu da seção crítica pendente do primeiro e re-enfileirou.
    found_in_queue =
      Enum.find(state_after_reject.request_queue, fn {priority, name, _ts, _status} ->
        name == mission_name and priority == 2
      end)

    is_processing_again = state_after_reject.request_for_process == mission_name

    assert found_in_queue != nil or is_processing_again

    :gen_tcp.close(drone_socket)
  end

  test "entra na secao critica quando unico peer desconecta e tenta alocar drone" do
    peer_port = 5054
    node_port = 5055

    {:ok, listen_socket} =
      :gen_tcp.listen(peer_port, [:binary, packet: :line, active: false, reuseaddr: true])

    System.put_env("HOSTS", "127.0.0.1:#{peer_port}")
    {:ok, _pid} = Sector.Node.start_link(tcp_port: node_port)

    {:ok, peer_server_socket} = :gen_tcp.accept(listen_socket, 2000)

    # Solicita SC
    send(Sector.Node, :try_critical_section)

    # Recebe o request
    assert {:ok, data} = :gen_tcp.recv(peer_server_socket, 0, 5000)
    assert %{"type" => "request"} = JSON.decode!(String.trim(data))

    # Não enviamos reply! Fechamos a conexão
    :gen_tcp.close(peer_server_socket)
    :gen_tcp.close(listen_socket)

    # Verifica se ele entra na seção crítica
    Process.sleep(1000)
    state = :sys.get_state(Sector.Node)
    assert state.in_critical_section? == true
    assert state.waiting_for_drone? == true
  end
end
