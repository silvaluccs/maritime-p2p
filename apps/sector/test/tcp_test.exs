defmodule Sector.TcpIntegrationTest do
  use ExUnit.Case, async: false

  setup do
    if pid = Process.whereis(Sector.TcpServer), do: GenServer.stop(pid)
    if pid = Process.whereis(Sector.TcpClient), do: GenServer.stop(pid)

    System.delete_env("HOSTS")
    :ok
  end

  describe "Sector.TcpServer" do
    test "inicia o servidor e responde a uma mensagem de ping" do
      port = 4001
      {:ok, _server_pid} = Sector.TcpServer.start_link(port)

      # Conecta um cliente TCP "puro" 
      {:ok, socket} =
        :gen_tcp.connect(~c"127.0.0.1", port, [:binary, packet: :line, active: false])

      ping_message = %{
        "type" => "ping",
        "from" => "test_client",
        "payload" => "Hello, Sector!"
      }

      :ok = :gen_tcp.send(socket, Jason.encode!(ping_message) <> "\n")

      # Aguarda a resposta do servidor
      assert {:ok, response_json} = :gen_tcp.recv(socket, 0, 1000)

      response = Jason.decode!(String.trim(response_json))
      assert response["type"] == "pong"
      assert String.contains?(response["payload"], "Pong response")

      :gen_tcp.close(socket)
    end

    test "falha ao iniciar em uma porta já em uso" do
      port = 4002
      {:ok, pid} = Sector.TcpServer.start_link(port)

      # Tentando iniciar o mesmo módulo, o GenServer vai reclamar do nome já registrado
      assert {:error, {:already_started, ^pid}} = Sector.TcpServer.start_link(port)
    end
  end

  describe "Sector.TcpClient" do
    test "le as variaveis de ambiente, conecta ao servidor e lista hosts conectados" do
      port = 4003
      # 1. Inicia um servidor TCP real para o cliente se conectar
      {:ok, _server_pid} = Sector.TcpServer.start_link(port)

      # 2. Configura a variável de ambiente (simulando um host válido e um inválido)
      System.put_env("HOSTS", "127.0.0.1:#{port}, localhost:99999, 127.0.0.1:erro")

      # 3. Inicia o cliente
      {:ok, _client_pid} = Sector.TcpClient.start_link()

      # Dá um tempinho pequeno para as conexões assíncronas ocorrerem
      Process.sleep(100)

      # 4. Verifica se conectou apenas no host válido
      connected = Sector.TcpClient.connected_hosts()

      assert length(connected) == 1
      assert hd(connected).address == "127.0.0.1:#{port}"
    end

    test "testa a funcionalidade send_to/2 e broadcast/1" do
      port1 = 4004
      # Iniciamos um servidor falso para apenas escutar o que o cliente manda
      {:ok, listen_socket} = :gen_tcp.listen(port1, [:binary, packet: :line, active: false])

      System.put_env("HOSTS", "127.0.0.1:#{port1}")
      {:ok, _client_pid} = Sector.TcpClient.start_link()

      # Aceitamos a conexão do cliente no nosso servidor falso
      {:ok, server_socket} = :gen_tcp.accept(listen_socket, 1000)

      # Aguarda o client registrar a conexão no state
      Process.sleep(50)

      # Testando broadcast
      msg = %{type: "status", payload: "ok"}

      expected_address = "127.0.0.1:#{port1}"

      assert Sector.TcpClient.broadcast(msg) == [{expected_address, :ok}]

      assert {:ok, received} = :gen_tcp.recv(server_socket, 0, 1000)
      assert String.contains?(received, "status")

      # Testando send_to
      assert :ok = Sector.TcpClient.send_to("127.0.0.1:#{port1}", %{type: "direct"})
      assert {:ok, received_direct} = :gen_tcp.recv(server_socket, 0, 1000)
      assert String.contains?(received_direct, "direct")

      :gen_tcp.close(server_socket)
      :gen_tcp.close(listen_socket)
    end
  end
end
