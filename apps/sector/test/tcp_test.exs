defmodule Sector.TcpIntegrationTest do
  use ExUnit.Case, async: false

  @passkey "08416EB34E46FD01C0E03B5E9B4AEACC06306F16D3E380559BBBAD8323C82A13"

  setup do
    # try/catch evita crash quando o processo morre entre whereis e stop
    Enum.each([Sector.TcpServer, Sector.TcpClient], fn mod ->
      if pid = Process.whereis(mod) do
        try do
          GenServer.stop(pid)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    unless Process.whereis(Sector.NodeId) do
      Sector.NodeId.start_link([])
    end

    System.delete_env("HOSTS")
    :ok
  end

  # Helper: conecta, aguarda o TcpServer processar {:new_client} e então envia auth.
  # O sleep evita a race condition onde o {:tcp, data} chega antes do {:new_client}
  # no mailbox do GenServer, fazendo o socket ser tratado como não-autenticado.
  defp connect_and_auth(port, id) do
    {:ok, socket} =
      :gen_tcp.connect(~c"127.0.0.1", port, [:binary, packet: :line, active: false])

    # Dá tempo para o TcpServer processar {:new_client} antes de enviar dados
    Process.sleep(30)

    auth = JSON.encode!(%{"type" => "auth", "id" => id, "passkey" => @passkey}) <> "\n"
    :ok = :gen_tcp.send(socket, auth)
    socket
  end

  describe "Sector.TcpServer" do
    test "inicia o servidor e responde a uma mensagem de ping" do
      port = 4001
      {:ok, _server_pid} = Sector.TcpServer.start_link(port)

      socket = connect_and_auth(port, "test_client")

      ping_message = %{
        "type" => "ping",
        "from" => "test_client",
        "payload" => "Hello, Sector!"
      }

      :ok = :gen_tcp.send(socket, JSON.encode!(ping_message) <> "\n")

      assert {:ok, response_json} = :gen_tcp.recv(socket, 0, 2000)
      response = JSON.decode!(String.trim(response_json))
      assert response["type"] == "pong"
      assert String.contains?(response["payload"], "Pong response")

      :gen_tcp.close(socket)
    end

    test "falha ao iniciar em uma porta já em uso" do
      port = 4002
      {:ok, pid} = Sector.TcpServer.start_link(port)
      assert {:error, {:already_started, ^pid}} = Sector.TcpServer.start_link(port)
    end
  end

  describe "Sector.TcpClient" do
    test "le as variaveis de ambiente, conecta ao servidor e lista hosts conectados" do
      port = 4003
      {:ok, _server_pid} = Sector.TcpServer.start_link(port)

      System.put_env("HOSTS", "127.0.0.1:#{port}, localhost:99999, 127.0.0.1:erro")
      {:ok, _client_pid} = Sector.TcpClient.start_link()

      # Tempo para conexão async + handshake de auth completar
      Process.sleep(300)

      connected = Sector.TcpClient.connected_hosts()
      assert length(connected) == 1
      assert hd(connected).address == "127.0.0.1:#{port}"
    end

    test "testa a funcionalidade send_to/2 e broadcast/1" do
      port1 = 4005

      {:ok, listen_socket} =
        :gen_tcp.listen(port1, [:binary, packet: :line, active: false, reuseaddr: true])

      System.put_env("HOSTS", "127.0.0.1:#{port1}")
      {:ok, _client_pid} = Sector.TcpClient.start_link()

      {:ok, server_socket} = :gen_tcp.accept(listen_socket, 1000)

      # TcpClient envia auth automaticamente ao conectar — consome antes de testar
      assert {:ok, auth_data} = :gen_tcp.recv(server_socket, 0, 2000)
      assert String.contains?(auth_data, "auth")

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
