defmodule Sector.TcpServer do
  @moduledoc """

  Servidor TCP para comunicação com outros setores e drones.
  Esse é o principal canal de setores e drones se comunicarem, enviando mensagens de status, comandos e atualizações de posição.
  Ao iniciar o setor, o servidor TCP é iniciado em uma porta específica (definida na configuração do setor) e fica escutando por conexões de clientes (outros setores e drones).

  """

  use GenServer
  require Logger

  alias Core.Protocol.{Message, Reply, Request}

  def start_link(port) when is_integer(port) do
    GenServer.start_link(__MODULE__, port, name: __MODULE__)
  end

  @impl true
  def init(port) do
    case(:gen_tcp.listen(port, [:binary, packet: :line, active: :once, reuseaddr: true])) do
      {:ok, socket} ->
        Logger.info("TCP server started on port #{port}")

        send(self(), :accept)

        {:ok, %{socket: socket}}

      {:error, reason} ->
        Logger.error("Failed to start TCP server: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def handle_info(:accept, state) do
    Task.start_link(fn ->
      case :gen_tcp.accept(state.socket) do
        {:ok, client_socket} ->
          Logger.info("Client connected")
          :ok = :gen_tcp.controlling_process(client_socket, Process.whereis(__MODULE__))
          send(Process.whereis(__MODULE__), :accept)

        {:error, _} ->
          :ok
      end
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info({:tcp, socket, data}, state) do
    data
    |> String.trim()
    |> decode_and_handle(socket)

    :inet.setopts(socket, active: :once)

    {:noreply, state}
  end

  @impl true
  def handle_info({:tcp_closed, _socket}, state) do
    Logger.info("Conexão de um cliente fechada pelo outro lado.")
    {:noreply, state}
  end

  @impl true
  def handle_info({:tcp_error, _socket, reason}, state) do
    Logger.error("Erro na conexão TCP do cliente: #{inspect(reason)}")
    {:noreply, state}
  end

  defp decode_and_handle(data, socket) do
    case JSON.decode(data) do
      {:ok, map} -> dispatch_message(map, socket)
      {:error, reason} -> Logger.error("Failed to decode JSON: #{inspect(reason)}")
    end
  end

  defp dispatch_message(%{"type" => "request"} = map, _socket) do
    case Request.from_map(map) do
      {:ok, request} -> Sector.Node.process_network_message(request)
      {:error, reason} -> Logger.error("Request inválido: #{inspect(reason)}")
    end
  end

  defp dispatch_message(%{"type" => "reply"} = map, _socket) do
    case Reply.from_map(map) do
      {:ok, reply} -> Sector.Node.process_network_message(reply)
      {:error, reason} -> Logger.error("Reply inválido: #{inspect(reason)}")
    end
  end

  defp dispatch_message(%{"type" => type} = map, socket) when type in ["ping", "pong"] do
    case Message.from_map(map) do
      {:ok, msg} -> Task.start(fn -> handle_message(msg, socket) end)
      {:error, _} -> Logger.error("Ping/Pong inválido: #{inspect(map)}")
    end
  end

  defp dispatch_message(map, _socket) do
    Logger.warning("Tipo de mensagem desconhecido: #{inspect(map)}")
  end

  defp handle_message(%Message{type: :ping, from: from}, socket) do
    Logger.info("Received ping from #{inspect(from)}")

    response = %Message{
      type: :pong,
      from: Sector.NodeId.get(),
      payload: "Pong response to #{from}"
    }

    encoded_response = JSON.encode!(response) <> "\n"
    :gen_tcp.send(socket, encoded_response)
  end
end
