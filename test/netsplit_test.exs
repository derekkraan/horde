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
end
