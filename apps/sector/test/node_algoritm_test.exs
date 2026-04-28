defmodule Sector.NodeAlgoritmTest do
  use ExUnit.Case, async: false

  setup do
    Enum.each([Sector.Node, Sector.TcpServer, Sector.TcpClient], fn mod ->
      if pid = Process.whereis(mod), do: GenServer.stop(pid)
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

    #  o node a tem um timer automático (1 a 6 seg). vamos esperar ele pedir a seção crítica.
    # o node a envia um "broadcast", então vamos receber isso no nosso peer_server_socket
    assert {:ok, data} = :gen_tcp.recv(peer_server_socket, 0, 7000)

    # verifica se a mensagem recebida é de fato um request válido
    assert %{"type" => "request", "clock" => req_clock, "from" => node_id} =
             JSON.decode!(String.trim(data))

    # Nós (Node B) enviamos o nosso Request PRIMEIRO!
    # Isso obriga o Node A a "adiar" o nosso pedido, pois ele mesmo está solicitando a seção.
    peer_request_msg = %{
      "type" => "request",
      "from" => "127.0.0.1:#{peer_port}",
      "to" => "broadcast",
      "clock" => 999,
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

    # O Node A vai entrar na seção crítica, sair imediatamente, e a primeira
    # coisa qur ele fará é desengavetar nosso pedido e nos mandar o "Reply".
    # Como TCP preserva a ordem, mesmo que ele mande outro Request depois,
    # o Reply chegará primeiro.
    assert {:ok, reply_data} = :gen_tcp.recv(peer_server_socket, 0, 5000)

    assert %{"type" => "reply", "from" => ^node_id} = JSON.decode!(String.trim(reply_data))

    # Limpeza dos Sockets de teste
    :gen_tcp.close(peer_client_socket)
    :gen_tcp.close(peer_server_socket)
    :gen_tcp.close(listen_socket)
  end
end
