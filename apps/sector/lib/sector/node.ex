defmodule Sector.Node do
  @moduledoc false

  alias Core.Protocol.{MissionAck, MissionReject, Reply, Request, SensorRequest, SensorStatus}

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

  @doc """
  Notifica o Node que um peer desconectou, para que ele reavalie
  se já pode entrar na seção crítica sem esperar mais replies.
  """
  def node_disconnected(address) do
    GenServer.cast(__MODULE__, {:node_disconnected, address})
  end

  @doc """
  Notifica o Node que um novo peer conectou. Se estivermos requisitando,
  enviamos nosso REQUEST para ele e o adicionamos ao conjunto de espera.
  """
  def peer_connected(address) do
    GenServer.cast(__MODULE__, {:peer_connected, address})
  end

  @doc """
  Notifica o Node que um drone desconectou (fechou conexão TCP).
  Se ele estava em missão, deve ser reenfileirado com prioridade 2.
  """
  def drone_disconnected(drone_id) do
    GenServer.cast(__MODULE__, {:drone_disconnected, drone_id})
  end

  @doc """
  Notifica o Node que um sensor desconectou.
  """
  def sensor_disconnected(sensor_id) do
    GenServer.cast(__MODULE__, {:sensor_disconnected, sensor_id})
  end

  def request_mission do
    send(Process.whereis(__MODULE__), :try_critical_section)
  end

  def get_queue do
    GenServer.call(__MODULE__, :get_queue)
  end

  @impl true
  def init(opts) do
    node_id = "#{System.get_env("NODE_NAME") || "127.0.0.1"}:#{opts[:tcp_port]}"

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
      request_for_process: nil,
      awaiting_replies: MapSet.new(),
      deferred_replies: MapSet.new(),
      drones_doing_mission: %{},
      available_drones: MapSet.new(),
      connected_sensors: MapSet.new(),
      waiting_for_drone?: false,
      request_queue: [],
      request_counter: 0,
      cs_heartbeat_timer: nil,
      pending_mission_ack: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:get_queue, _from, state) do
    {:reply, state.request_queue, state}
  end

  @impl true
  def handle_cast({:node_disconnected, address}, state) do
    Logger.info("Peer #{address} desconectou. Reavaliando seção crítica...")

    if state.requesting? and not state.in_critical_section? do
      new_awaiting = MapSet.delete(state.awaiting_replies, address)
      state = %{state | awaiting_replies: new_awaiting}

      if MapSet.size(new_awaiting) == 0 do
        Logger.info(
          "Todos os peers vivos já responderam (ou não há peers). Entrando na seção crítica."
        )

        {:noreply, enter_critical_section(state)}
      else
        {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:peer_connected, address}, state) do
    if state.requesting? and not state.in_critical_section? do
      Logger.info(
        "[REQUEST] Novo peer #{address} conectou enquanto requisitando. Re-enviando REQUEST (TS=#{state.request_ts}, P=#{state.request_priority})."
      )

      request_msg = %Request{
        type: :request,
        from: state.node_id,
        to: address,
        clock: state.request_ts,
        priority: state.request_priority
      }

      Sector.TcpClient.send_to(address, request_msg)
      {:noreply, %{state | awaiting_replies: MapSet.put(state.awaiting_replies, address)}}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:drone_disconnected, drone_id}, state) do
    Logger.warning("Drone #{drone_id} desconectou!")

    new_available = MapSet.delete(state.available_drones, drone_id)
    {mission_name, new_doing} = Map.pop(state.drones_doing_mission, drone_id)

    state = %{state | available_drones: new_available, drones_doing_mission: new_doing}

    state =
      if mission_name do
        Logger.warning(
          "Drone #{drone_id} caiu durante a missão #{mission_name}. Re-enfileirando com prioridade 2!"
        )

        new_clock = state.clock + 1
        requeued = {2, mission_name, new_clock, :waiting}
        new_queue = insert_request_in_queue(state.request_queue, requeued)

        %{state | request_queue: new_queue, clock: new_clock}
      else
        state
      end

    {:noreply, maybe_start_request(state)}
  end

  @impl true
  def handle_cast({:network_message, %Core.Protocol.DroneStatus{} = status}, state) do
    Logger.info("Recebido status do drone #{status.drone_id}: #{status.status}")

    {new_available, new_doing} =
      if status.status == "IDLE" do
        {
          MapSet.put(state.available_drones, status.drone_id),
          Map.delete(state.drones_doing_mission, status.drone_id)
        }
      else
        {
          MapSet.delete(state.available_drones, status.drone_id),
          state.drones_doing_mission
        }
      end

    new_state = %{state | available_drones: new_available, drones_doing_mission: new_doing}

    if new_state.in_critical_section? and new_state.waiting_for_drone? and status.status == "IDLE" do
      allocate_drone(new_state)
    else
      {:noreply, new_state}
    end
  end

  @impl true
  def handle_cast({:network_message, %MissionAck{} = ack}, state) do
    case state.pending_mission_ack do
      nil ->
        Logger.warning(
          "[CS] MissionAck recebido de #{ack.drone_id} mas não havia missão pendente. Ignorando."
        )

        {:noreply, state}

      {mission_name, _original_clock} ->
        IO.puts(
          "\n=== [SHELL] [CS] ✅ MissionAck recebido do drone #{ack.drone_id} para '#{mission_name}'. Saindo da seção crítica. ==="
        )

        Logger.info(
          "[CS] MissionAck do drone #{ack.drone_id} para '#{mission_name}'. Saindo da CS."
        )

        send(self(), :exit_critical_section)
        {:noreply, %{state | pending_mission_ack: nil}}
    end
  end

  @impl true
  def handle_cast({:network_message, %MissionReject{} = rej}, state) do
    case state.pending_mission_ack do
      nil ->
        Logger.warning(
          "[CS] MissionReject recebido de #{rej.drone_id} mas não havia missão pendente. Ignorando."
        )

        {:noreply, state}

      {mission_name, original_clock} ->
        IO.puts(
          "\n=== [SHELL] [CS] ⚠️  MissionReject do drone #{rej.drone_id}! Re-enfileirando '#{mission_name}' com PRIORIDADE 2, clock original #{original_clock}. ==="
        )

        Logger.warning(
          "[CS] MissionReject do drone #{rej.drone_id}. Re-enfileirando '#{mission_name}' (clock=#{original_clock}) com prioridade 2."
        )

        # Re-insere com prioridade 2 e clock ORIGINAL
        requeued = {2, mission_name, original_clock, :waiting}
        new_queue = insert_request_in_queue(state.request_queue, requeued)

        new_state = %{state | pending_mission_ack: nil, request_queue: new_queue}

        send(self(), :exit_critical_section)
        {:noreply, new_state}
    end
  end

  @impl true
  def handle_cast({:network_message, %Request{} = req}, state) do
    Logger.info("Recebido Request de #{req.from} com clock #{req.clock}")

    IO.puts(
      "=== [SHELL] [REDE] Recebido Request de #{req.from} (Clock: #{req.clock}, Prio: #{req.priority}) ==="
    )

    handle_request(req.from, req.clock, req.priority, state)
  end

  @impl true
  def handle_cast({:network_message, %Reply{} = reply}, state) do
    Logger.info("Recebido Reply de #{reply.from}")
    IO.puts("=== [SHELL] [REDE] Recebido Reply de #{reply.from} ===")
    handle_reply(reply.from, state)
  end

  @impl true
  def handle_cast({:sensor_disconnected, sensor_id}, state) do
    Logger.warning("Sensor #{sensor_id} desconectou!")
    new_sensors = MapSet.delete(state.connected_sensors, sensor_id)
    {:noreply, %{state | connected_sensors: new_sensors}}
  end

  @impl true
  def handle_cast({:network_message, %SensorStatus{} = status}, state) do
    Logger.info("Recebido status do sensor #{status.sensor_id}: #{status.status}")
    new_sensors = MapSet.put(state.connected_sensors, status.sensor_id)
    {:noreply, %{state | connected_sensors: new_sensors}}
  end

  @impl true
  def handle_cast({:network_message, %SensorRequest{} = req}, state) do
    Logger.info(
      "Recebido Request do Sensor #{req.sensor_id}: #{req.reason} (Prioridade: #{req.priority})"
    )

    new_clock = state.clock + 1
    new_counter = state.request_counter + 1

    request_name = "SENSOR #{new_counter} | MOTIVO: #{req.reason} | CLOCK #{new_clock}"

    request = {req.priority, request_name, new_clock, :waiting}

    new_request_tree = insert_request_in_queue(state.request_queue, request)

    queue_format =
      Enum.map_join(new_request_tree, "\n", fn {p, name, ts, _status} ->
        "#{name} PRIORIDADE #{p} TS #{ts}"
      end)

    IO.puts("\n=== [SHELL] Missão de Sensor enfileirada. FILA=\n#{queue_format} ===")

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
  def handle_info(:try_critical_section, state) do
    {:ok, request, new_clock, new_counter} = create_request(state.clock, state.request_counter)

    new_request_tree =
      insert_request_in_queue(state.request_queue, request)

    queue_format =
      Enum.map_join(new_request_tree, "\n", fn {p, name, ts, _status} ->
        "#{name} PRIORIDADE #{p} TS #{ts}"
      end)

    IO.puts("\n=== [SHELL] Nova missão enfileirada. FILA=\n#{queue_format} ===")
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
  def handle_info(:log_critical_section, state) when not state.in_critical_section? do
    {:noreply, state}
  end

  @impl true
  def handle_info(:log_critical_section, state) do
    Logger.info(
      "[CS] EM SEÇÃO CRÍTICA. Missão: #{state.request_for_process} | Clock: #{state.clock}"
    )

    timer = Process.send_after(self(), :log_critical_section, 1_000)
    {:noreply, %{state | cs_heartbeat_timer: timer}}
  end

  @impl true
  def handle_info(:exit_critical_section, state) when not state.in_critical_section? do
    Logger.debug("Mensagem :exit_critical_section ignorada — não estava na seção crítica")
    {:noreply, state}
  end

  @impl true
  def handle_info(:exit_critical_section, state) do
    IO.puts(
      "\n===========================================\n[SHELL] => REQUEST CONCLUÍDO COM SUCESSO! <=\n===========================================\n"
    )

    queue_format =
      Enum.map_join(state.request_queue, "\n", fn {p, name, ts, _status} ->
        "#{name} PRIORIDADE #{p} TS #{ts}"
      end)

    Logger.info("Fila de requisições\n#{queue_format}")

    Enum.each(state.deferred_replies, fn {deferred_node, _ts} ->
      reply_msg = %Reply{
        type: :reply,
        from: state.node_id,
        to: deferred_node,
        clock: state.clock
      }

      IO.puts("=== [SHELL] Enviando REPLY (adiado) para #{deferred_node} ===")
      Sector.TcpClient.send_to(deferred_node, reply_msg)
    end)

    new_state = %{
      state
      | in_critical_section?: false,
        requesting?: false,
        request_ts: nil,
        request_priority: 0,
        awaiting_replies: MapSet.new(),
        deferred_replies: MapSet.new(),
        pending_mission_ack: nil
    }

    new_state = maybe_start_request(new_state)
    {:noreply, new_state}
  end

  defp maybe_start_request(state) do
    if not state.requesting? and not state.in_critical_section? and state.request_queue != [] do
      {priority, name, _queue_clock, _doing} = get_next_request(state.request_queue)

      new_queue = remove_mission_complete_from_priority_queue(state.request_queue, name)

      network_clock = state.clock + 1

      request_msg = %Request{
        type: :request,
        from: state.node_id,
        to: :broadcast,
        clock: network_clock,
        priority: priority
      }

      IO.puts(
        "\n=== [SHELL] Enviando REQUEST (Clock: #{network_clock}, Prioridade: #{priority}) para os outros setores... ==="
      )

      Sector.TcpClient.broadcast(request_msg)

      connected = Sector.TcpClient.connected_hosts()
      awaiting = MapSet.new(connected, & &1.address)

      state = %{
        state
        | clock: network_clock,
          requesting?: true,
          request_ts: network_clock,
          request_priority: priority,
          awaiting_replies: awaiting,
          request_for_process: name,
          request_queue: new_queue
      }

      if MapSet.size(awaiting) == 0 do
        enter_critical_section(state)
      else
        state
      end
    else
      state
    end
  end

  defp get_next_request(priority_queue) do
    request_with_higher_priority = List.first(priority_queue)
    request_with_lower_priority = List.last(priority_queue)

    head_priority = elem(request_with_higher_priority, 0)
    tail_priority = elem(request_with_lower_priority, 0)

    head_clock = elem(request_with_higher_priority, 2)
    tail_clock = elem(request_with_lower_priority, 2)

    cond do
      head_priority == 2 ->
        request_with_higher_priority

      head_clock - tail_clock >= 20 ->
        request_with_lower_priority

      head_priority > tail_priority ->
        request_with_higher_priority

      true ->
        request_with_higher_priority
    end
  end

  defp create_request(clock, request_counter) do
    priority = Enum.random([0, 1])

    new_counter = request_counter + 1
    new_clock = clock + 1

    request_name = "REQUEST #{new_counter} | CLOCK #{new_clock}"

    request = {priority, request_name, new_clock, :waiting}

    {:ok, request, new_clock, new_counter}
  end

  defp insert_request_in_queue(queue, request) do
    (queue ++ [request])
    |> Enum.sort_by(fn {priority, _name, timestamp, _status} -> {priority, timestamp} end, :desc)
  end

  defp handle_request(from_id, request_ts, request_priority, state) do
    new_clock = max(state.clock, request_ts) + 1
    state = %{state | clock: new_clock}

    cond do
      state.in_critical_section? ->
        Logger.info(
          "[REQUEST] ADIANDO reply para #{from_id} — estou na seção crítica." <>
            " Meu clock: #{state.clock} | TS do request: #{request_ts}"
        )

        IO.puts("=== [SHELL] [ALGORITMO] ADIANDO reply para #{from_id} (Na Seção Crítica) ===")

        {:noreply,
         %{state | deferred_replies: MapSet.put(state.deferred_replies, {from_id, request_ts})}}

      not state.requesting? ->
        Logger.info(
          "[REQUEST] ACEITANDO request de #{from_id} — não estou requisitando." <>
            " Meu clock: #{state.clock} | TS do request: #{request_ts}"
        )

        IO.puts(
          "=== [SHELL] [ALGORITMO] ACEITANDO request de #{from_id} (Não estou requisitando) -> Enviando REPLY ==="
        )

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
        state.node_id,
        request_ts,
        request_priority,
        from_id
      ) ->
        Logger.info(
          "[REQUEST] ADIANDO reply para #{from_id} — tenho prioridade." <>
            " Meu TS: #{state.request_ts} prioridade #{state.request_priority}" <>
            " | TS do request: #{request_ts} prioridade #{request_priority}"
        )

        IO.puts("=== [SHELL] [ALGORITMO] ADIANDO reply para #{from_id} (Tenho prioridade) ===")

        {:noreply,
         %{state | deferred_replies: MapSet.put(state.deferred_replies, {from_id, request_ts})}}

      true ->
        Logger.info(
          "[REQUEST] ACEITANDO request de #{from_id} — ele tem prioridade." <>
            " Meu TS: #{state.request_ts} prioridade #{state.request_priority}" <>
            " | TS do request: #{request_ts} prioridade #{request_priority}"
        )

        IO.puts(
          "=== [SHELL] [ALGORITMO] ACEITANDO request de #{from_id} (Ele tem prioridade) -> Enviando REPLY ==="
        )

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

  defp i_have_priotity_over?(my_ts, _my_priority, my_id, other_ts, _other_priority, other_id) do
    cond do
      my_ts < other_ts -> true
      my_ts > other_ts -> false
      my_id < other_id -> true
      true -> false
    end
  end

  defp handle_reply(from_id, state) do
    if state.requesting? and not state.in_critical_section? do
      new_awaiting = MapSet.delete(state.awaiting_replies, from_id)
      state = %{state | awaiting_replies: new_awaiting, clock: state.clock + 1}

      Logger.info(
        "[REPLY] Recebido de #{from_id}. Aguardando ainda: #{inspect(MapSet.to_list(new_awaiting))}"
      )

      IO.puts(
        "=== [SHELL] [ALGORITMO] Faltam respostas de: #{inspect(MapSet.to_list(new_awaiting))} ==="
      )

      if MapSet.size(new_awaiting) == 0 do
        {:noreply, enter_critical_section(state)}
      else
        {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  defp remove_mission_complete_from_priority_queue(priority_queue, mission_name) do
    Enum.filter(priority_queue, fn {_, name, _, _} -> name != mission_name end)
  end

  defp enter_critical_section(state) do
    if state.cs_heartbeat_timer, do: Process.cancel_timer(state.cs_heartbeat_timer)

    Logger.info("[CS] Entrando na seção crítica.")
    IO.puts("=== [SHELL] [CS] Todas as permissões concedidas! Entrando na Seção Crítica. ===")
    timer = Process.send_after(self(), :log_critical_section, 1_000)

    state = %{
      state
      | in_critical_section?: true,
        cs_heartbeat_timer: timer,
        waiting_for_drone?: true
    }

    # Tenta alocar um drone assim que entra na seção crítica
    {_noreply, state} = allocate_drone(state)
    state
  end

  defp allocate_drone(state) do
    if state.waiting_for_drone? do
      if MapSet.size(state.available_drones) > 0 do
        drone_id = Enum.random(MapSet.to_list(state.available_drones))

        IO.puts(
          "\n=== [SHELL] [CS] Alocando drone #{drone_id} para a missão #{state.request_for_process}. ==="
        )

        Logger.info("[CS] Alocando drone #{drone_id} para a missão #{state.request_for_process}.")

        mission_msg = %Core.Protocol.Mission{
          type: :mission,
          drone_id: drone_id,
          from: state.node_id,
          mission_name: state.request_for_process,
          clock: state.request_ts
        }

        encoded = JSON.encode!(mission_msg) <> "\n"
        Sector.TcpServer.broadcast(encoded)

        new_doing = Map.put(state.drones_doing_mission, drone_id, state.request_for_process)

        state = %{
          state
          | waiting_for_drone?: false,
            available_drones: MapSet.delete(state.available_drones, drone_id),
            drones_doing_mission: new_doing,
            pending_mission_ack: {state.request_for_process, state.request_ts}
        }

        IO.puts("=== [SHELL] [CS] Aguardando ACK/REJECT do drone #{drone_id}... ===")
        Logger.info("[CS] Missão enviada para #{drone_id}. Aguardando MissionAck/MissionReject.")

        {:noreply, state}
      else
        Logger.info("[CS] Aguardando um drone ficar disponível...")
        {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end
end
