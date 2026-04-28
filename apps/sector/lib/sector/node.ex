defmodule Sector.Node do
  @moduledoc false

  alias Core.Protocol.{Reply, Request}

  require Logger
  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Recebe uma struct de mensagem vinda da rede e a coloca na fila do GenServer
  para processamento sequencial e seguro.
  """
  def process_network_message(message_struct) do
    GenServer.cast(__MODULE__, {:network_message, message_struct})
  end

  @impl true
  def init(opts) do
    # node_id = Sector.NodeId.get()
    node_id = "127.0.0.1:#{opts[:tcp_port]}"

    children = [
      {Sector.TcpServer, opts[:tcp_port]},
      {Sector.TcpClient, []}
    ]

    Supervisor.start_link(children, strategy: :one_for_one)

    state = %{
      node_id: node_id,
      clock: 0,
      requesting?: false,
      in_critical_section?: false,
      request_ts: nil,
      request_priority: 0,
      replies_received: MapSet.new(),
      deferred_replies: MapSet.new(),
      request_queue: [],
      request_counter: 0
    }

    schedule_next_attempt()
    {:ok, state}
  end

  @impl true
  def handle_cast({:network_message, %Request{} = req}, state) do
    Logger.info("Recebido Request de #{req.from} com clock #{req.clock}")
    handle_request(req.from, req.clock, req.priority, state)
  end

  @impl true
  def handle_cast({:network_message, %Reply{} = reply}, state) do
    Logger.info("Recebido Reply de #{reply.from}")
    handle_reply(reply.from, state)
  end

  @impl true
  def handle_info(:try_critical_section, state) do
    schedule_next_attempt()

    {:ok, request, new_clock, new_counter} = create_request(state.clock, state.request_counter)

    new_request_tree =
      insert_request_in_queue(state.request_queue, request)

    queue_format =
      Enum.map_join(new_request_tree, "\n", fn {p, name, ts} ->
        "#{name} PRIORIDADE #{p} TS #{ts}"
      end)

    Logger.info("Nova missão enfileirada. FILA=\n#{queue_format}")

    new_state = %{
      state
      | request_queue: new_request_tree,
        request_counter: new_counter,
        clock: new_clock
    }

    new_state = maybe_start_request(new_state)

    {:noreply, new_state}
  end

  @impl true
  def handle_info(:exit_critical_section, state) do
    Logger.info("Saindo da seção crítica")

    Enum.each(state.deferred_replies, fn {deferred_node, _ts} ->
      reply_msg = %Reply{
        type: :reply,
        from: state.node_id,
        to: deferred_node,
        clock: state.clock
      }

      Sector.TcpClient.send_to(deferred_node, reply_msg)
    end)

    new_state = %{
      state
      | in_critical_section?: false,
        requesting?: false,
        request_ts: nil,
        request_priority: 0,
        replies_received: MapSet.new(),
        deferred_replies: MapSet.new()
    }

    new_state = maybe_start_request(new_state)
    {:noreply, new_state}
  end

  defp maybe_start_request(state) do
    if not state.requesting? and not state.in_critical_section? and state.request_queue != [] do
      [{priority, _name, clock} | rest_queue] = state.request_queue
      state = %{state | request_queue: rest_queue}

      request_msg = %Request{
        type: :request,
        from: state.node_id,
        to: :broadcast,
        clock: clock,
        priority: priority
      }

      Sector.TcpClient.broadcast(request_msg)

      state = %{
        state
        | clock: clock,
          requesting?: true,
          request_ts: clock,
          request_priority: priority,
          replies_received: MapSet.new()
      }

      if Sector.TcpClient.connected_hosts() == [] do
        enter_critical_section(state)
      else
        state
      end
    else
      state
    end
  end

  defp create_request(clock, request_counter) do
    priority = Enum.random([0, 1])

    new_counter = request_counter + 1
    new_clock = clock + 1

    request_name = "REQUEST #{new_counter}"
    request = {priority, request_name, new_clock}

    {:ok, request, new_clock, new_counter}
  end

  defp insert_request_in_queue(queue, request) do
    (queue ++ [request])
    |> Enum.sort_by(fn {priority, _name, timestamp} -> {priority, timestamp} end, :desc)
  end

  defp schedule_next_attempt do
    Process.send_after(self(), :try_critical_section, random_delay_ms())
  end

  defp random_delay_ms do
    :rand.uniform(5000) + 1000
  end

  defp handle_request(from_id, request_ts, request_priority, state) do
    new_clock = max(state.clock, request_ts) + 1
    state = %{state | clock: new_clock}

    cond do
      state.in_critical_section? ->
        {:noreply,
         %{state | deferred_replies: MapSet.put(state.deferred_replies, {from_id, request_ts})}}

      not state.requesting? ->
        reply_msg = %Reply{
          type: :reply,
          from: state.node_id,
          to: from_id,
          clock: new_clock
        }

        Sector.TcpClient.send_to(from_id, reply_msg)
        {:noreply, state}

      i_have_priotity_over?(
        state.request_ts,
        state.request_priority,
        request_ts,
        request_priority
      ) ->
        {:noreply,
         %{state | deferred_replies: MapSet.put(state.deferred_replies, {from_id, request_ts})}}

      true ->
        reply_msg = %Reply{
          type: :reply,
          from: state.node_id,
          to: from_id,
          clock: new_clock
        }

        Sector.TcpClient.send_to(from_id, reply_msg)
        {:noreply, state}
    end
  end

  defp i_have_priotity_over?(my_ts, my_priority, other_ts, other_priority) do
    cond do
      my_priority > other_priority -> true
      my_priority < other_priority -> false
      my_ts < other_ts -> true
      my_ts > other_ts -> false
      true -> false
    end
  end

  defp handle_reply(from_id, state) do
    if state.requesting? and not state.in_critical_section? do
      received_replies = MapSet.put(state.replies_received, from_id)
      state = %{state | replies_received: received_replies, clock: state.clock + 1}

      if MapSet.size(received_replies) >= length(Sector.TcpClient.connected_hosts()) do
        {:noreply, enter_critical_section(state)}
      else
        {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  defp enter_critical_section(state) do
    send(self(), :exit_critical_section)
    %{state | in_critical_section?: true}
  end
end
