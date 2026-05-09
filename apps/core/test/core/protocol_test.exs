defmodule Core.ProtocolTest do
  use ExUnit.Case, async: true
  alias Core.Protocol.{DroneStatus, Mission, MissionAck, MissionReject, Reply, Request}

  test "Request from_map converte corretamente" do
    map = %{
      "type" => "request",
      "from" => "nodeA",
      "to" => "nodeB",
      "clock" => 5,
      "priority" => 1
    }

    assert {:ok, req} = Request.from_map(map)
    assert req.type == :request
    assert req.from == "nodeA"
    assert req.to == "nodeB"
    assert req.clock == 5
    assert req.priority == 1
  end

  test "Reply from_map converte corretamente" do
    map = %{"type" => "reply", "from" => "nodeB", "to" => "nodeA", "clock" => 6, "priority" => 0}
    assert {:ok, rep} = Reply.from_map(map)
    assert rep.type == :reply
  end

  test "DroneStatus, Mission, Ack e Reject from_map convertem corretamente" do
    assert {:ok, %DroneStatus{type: :drone_status, drone_id: "d1", status: "IDLE"}} =
             DroneStatus.from_map(%{
               "type" => "drone_status",
               "drone_id" => "d1",
               "status" => "IDLE"
             })

    assert {:ok, %Mission{type: :mission, drone_id: "d1", from: "nodeA"}} =
             Mission.from_map(%{"type" => "mission", "drone_id" => "d1", "from" => "nodeA"})

    assert {:ok, %MissionAck{type: :mission_ack, drone_id: "d1", to: "nodeA"}} =
             MissionAck.from_map(%{"type" => "mission_ack", "drone_id" => "d1", "to" => "nodeA"})

    assert {:ok,
            %MissionReject{
              type: :mission_reject,
              drone_id: "d1",
              to: "nodeA",
              mission_name: "m1",
              clock: 2
            }} =
             MissionReject.from_map(%{
               "type" => "mission_reject",
               "drone_id" => "d1",
               "to" => "nodeA",
               "mission_name" => "m1",
               "clock" => 2
             })
  end

  test "from_map retorna erro para maps invalidos" do
    assert {:error, :invalid_message} = Request.from_map(%{"type" => "unknown"})
  end
end
