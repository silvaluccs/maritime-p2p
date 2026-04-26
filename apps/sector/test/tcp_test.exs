defmodule Sector.TcpTest do
  use ExUnit.Case

  test "Iniciando um servidor TCP e conectando um cliente" do
    port = 4000
    {:ok, _pid} = Sector.TcpServer.start_link(port)

    {:ok, socket} = :gen_tcp.connect(~c"localhost", port, [:binary, packet: :line])

    test_message = %{
      "type" => "ping",
      "from" => "test_client",
      "payload" => "Hello, Sector!"
    }

    :gen_tcp.send(socket, Jason.encode!(test_message) <> "\n")

    {ok, server_response} = :gen_tcp.recv(socket, 0)

    :gen_tcp.close(socket)
  end

  test "Iniciando um servidor TCP em uma porta já em uso" do
    port = 5000
    {:ok, pid} = Sector.TcpServer.start_link(port)

    {:error, reason} = Sector.TcpServer.start_link(port)

    assert reason == {:already_started, pid}
  end
end
