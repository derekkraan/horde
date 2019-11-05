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

  test "process redistribution after netsplit" do
    cluster_name = "node"
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
        [
          [
            cluster: cluster_name,
            distribution: Horde.UniformDistribution,
            sync_interval: 100
          ]
        ]
      ])
    end)

    # Wait for supervisor and registry in all nodes
    Process.sleep(sleep_millis)

    Enum.each(nodes, fn node ->
      assert MySupervisor.alive?(node)
      assert MyRegistry.alive?(node)
    end)

    # Start 10 servers. Processes should be distributed across all three
    # nodes in the cluster
    servers = 10

    1..servers
    |> Enum.each(fn n ->
      {:ok, _} = MyCluster.start_server(node1, server_name(n))
    end)

    Process.sleep(sleep_millis)

    # Ensure all servers are running in one of the 3 nodes of the
    # clusters.
    ensure_servers_in_nodes(servers, nodes)

    Process.sleep(sleep_millis)

    # Create a network partition. Node3 is now isolated from the other
    # two nodes
    Schism.partition([node3])

    Process.sleep(sleep_millis)

    Enum.each(nodes, fn node ->
      assert MySupervisor.alive?(node)
      assert MyRegistry.alive?(node)
    end)

    # Verify all 10 servers are now living in the partition
    # formed by node1 and node2. We verify this for each one of the ten
    # servers started, and we verify the view on that process is
    # consistent from both nodes of the partition, ie, both nodes see
    # the same pid and that pid is in one of those nodes
    ensure_servers_in_nodes(servers, [node1, node2])
  end

  defp server_name(n), do: "server#{n}"

  # Convenience function that inspects each server, and fails the test
  # if necessary
  defp ensure_servers_in_nodes(count, nodes) do
    1..count
    |> Enum.each(fn n ->
      name = server_name(n)

      case MyCluster.server_in_nodes?(nodes, name) do
        false ->
          flunk(
            "Server #{name} not running in one of: #{inspect(nodes)}. Debug: #{
              inspect(MyCluster.debug(nodes))
            }"
          )

        true ->
          :ok
      end
    end)
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
        [
          [
            cluster: cluster_name,
            distribution: Horde.UniformQuorumDistribution,
            sync_interval: 100
          ]
        ]
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
