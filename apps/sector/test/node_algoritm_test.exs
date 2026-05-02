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

    # O Node A vai entrar na seção crítica (demora ~10s na SC no atual node.ex)
    # E quando sair, vai desengavetar nosso pedido e nos mandar o "Reply".
    assert {:ok, reply_data} = :gen_tcp.recv(peer_server_socket, 0, 15000)

    assert %{"type" => "reply", "from" => ^node_id} = JSON.decode!(String.trim(reply_data))

    # Limpeza dos Sockets de teste
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

  test "entra na secao critica quando unico peer desconecta" do
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

    # Verifica se ele entra na seção crítica (ele vai logar, ou podemos checar o estado via :sys.get_state)
    Process.sleep(1000)
    state = :sys.get_state(Sector.Node)
    assert state.in_critical_section? == true
  end
end
