defmodule Dynamic.EntityTest do
  use ExUnit.Case
  alias Dynamic.Entity

  describe "multiple nodes" do
    setup do
      [node1, node2] =
        nodes = LocalCluster.start_nodes("test-dynamic-entity", 2, files: [__ENV__.file])

      IO.inspect(nodes, label: "Test nodes that are now online")

      # Ensure online
      assert Node.ping(node1) == :pong
      assert Node.ping(node2) == :pong

      Horde.Supervisor.wait_for_quorum(Dynamic.EntitySupervisor, 30_000)

      Dynamic.create_entity("one", %{one: "data"})
      Dynamic.create_entity("two", %{two: "data"})
      Dynamic.create_entity("three", %{three: "data"})
      Dynamic.create_entity("four", %{four: "data"})
      Dynamic.create_entity("five", %{five: "data"})

      # Wait for eventual consistency of registries
      Process.sleep(100)

      entity_one = Dynamic.get_entity_pid("one")
      entity_two = Dynamic.get_entity_pid("two")
      entity_three = Dynamic.get_entity_pid("three")
      entity_four = Dynamic.get_entity_pid("four")
      entity_five = Dynamic.get_entity_pid("five")

      entities = [entity_one, entity_two, entity_three, entity_four, entity_five]

      node1_entity = entities |> Enum.find(&(node(&1) == node1))
      assert node1_entity
      {node1_entity_str, node1_entity_data} = Entity.get_data(node1_entity)
      node2_entity = entities |> Enum.find(&(node(&1) == node2))
      assert node2_entity
      {node2_entity_str, node2_entity_data} = Entity.get_data(node2_entity)

      %{
        node1: node1,
        node2: node2,
        nodes: nodes,
        node1_entity: node1_entity,
        node2_entity: node2_entity,
        node1_entity_data: node1_entity_data,
        node2_entity_data: node2_entity_data,
        node1_entity_str: node1_entity_str,
        node2_entity_str: node2_entity_str
      }
    end

    # Testing that other nodes can see the same registry data
    test "entity data fetch from other nodes", %{
      node1: node1,
      node1_entity: node1_entity,
      node1_entity_str: node1_entity_str,
      node1_entity_data: node1_entity_data,
      node2: node2,
      node2_entity: node2_entity,
      node2_entity_str: node2_entity_str,
      node2_entity_data: node2_entity_data
    } do
      tester = self()

      # Try to find the entity pid from node 2
      Node.spawn(node2, fn ->
        send(tester, Dynamic.get_entity(node1_entity_str))
      end)

      assert_receive ^node1_entity_data, 100

      # Try to find the entity pid from node 1
      Node.spawn(node1, fn ->
        send(tester, Dynamic.get_entity(node2_entity_str))
      end)

      assert_receive ^node2_entity_data, 100
    end

    # Testing what our logic does when a node goes down, and to make sure
    # we have everything configured right with horde
    test "a node goes down", %{
      node1: node1,
      node1_entity_str: node1_entity_str,
      node1_entity_data: node1_entity_data
    } do
      # Oh noes! a node goes down!
      :ok = LocalCluster.stop_nodes([node1])

      # Ensure node1 is not reachable
      assert Node.ping(node1) == :pang

      Process.sleep(100)

      # Node1's data got moved to another node
      assert Dynamic.get_entity(node1_entity_str) == node1_entity_data
    end
  end
end
