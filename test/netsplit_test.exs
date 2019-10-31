defmodule NetsplitTest do
  use ExUnit.Case

  @tag :skip
  test "supervisor recovers after netsplit" do
    [node1, node2] = nodes = LocalCluster.start_nodes("cluster-", 2)

    Enum.each(nodes, fn node ->
      assert :pong = Node.ping(node)
    end)

    [sup | _] = supervisors = Enum.map(nodes, fn node -> {:horde_supervisor, node} end)

    Enum.each(supervisors, fn {name, node} ->
      Node.spawn(node, LocalClusterHelper, :start, [
        Horde.DynamicSupervisor,
        :start_link,
        [[strategy: :one_for_one, name: name, members: supervisors]]
      ])
    end)

    Process.sleep(1000)

    Horde.DynamicSupervisor.start_child(sup, %{
      id: :first_child,
      start: {EchoServer, :start_link, [self()]}
    })

    assert_receive {n, :hello_echo_server}
    [other_node] = nodes -- [n]
    refute_receive {^other_node, :hello_echo_server}, 1000

    Schism.partition([node1])

    assert_receive {^node1, :hello_echo_server}, 60_000
    assert_receive {^node2, :hello_echo_server}, 60_000

    Schism.heal(nodes)

    assert_receive {^other_node, :hello_echo_server}, 1100
    refute_receive {^n, :hello_echo_server}, 1100
  end

  test "name conflict after healing netsplit" do
    cluster_name = "cluster"
    server_name = "server"
    sleep_millis = 2000

    [node1, node2, node3] = nodes = LocalCluster.start_nodes(cluster_name, 3)

    Enum.each(nodes, fn node ->
      assert :pong = Node.ping(node)
    end)

    # Start a test supervision tree in all three nodes
    Enum.each(nodes, fn node ->
      Node.spawn(node, LocalClusterHelper, :start, [
        MySupervisionTree,
        :start_link,
        [[cluster: cluster_name, distribution: Horde.UniformQuorumDistribution, sync_interval: 5]]
      ])
    end)

    # Wait for supervisor and registry in all nodes
    Process.sleep(sleep_millis)

    Enum.each(nodes, fn node ->
      assert MySupervisor.alive?(node)
      assert MyRegistry.alive?(node)
    end)

    Schism.partition([node1, node2])
    Schism.partition([node3])

    Process.sleep(sleep_millis)

    Enum.each(nodes, fn node ->
      assert MySupervisor.alive?(node)
      assert MyRegistry.alive?(node)
    end)

    # Create a server with the same name in both partitions
    {:ok, pid1} = MyCluster.start_server(node1, server_name)
    {:ok, pid2} = MyCluster.start_server(node3, server_name)

    assert Enum.member?([node1, node2], node(pid1))
    assert node3 == node(pid2)

    Process.sleep(sleep_millis)

    # Heal the cluster
    Schism.heal(nodes)
    Process.sleep(sleep_millis)

    Enum.each(nodes, fn node ->
      assert MySupervisor.alive?(node)
      assert MyRegistry.alive?(node)
    end)

    # Verify all nodes are able to see the same pid for that server
    pid1 = MyCluster.whereis_server(node1, server_name)
    pid2 = MyCluster.whereis_server(node2, server_name)
    pid3 = MyCluster.whereis_server(node3, server_name)

    assert is_pid(pid1)
    assert pid1 == pid2
    assert pid1 == pid3
    assert pid2 == pid3
  end
end
