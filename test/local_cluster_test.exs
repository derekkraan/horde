defmodule LocalClusterTest do
  require Logger
  use ExUnit.Case, async: false

  setup do
    nodes = LocalCluster.start_nodes("cluster-#{:rand.uniform(1000)}", 2)

    _ =
      for n <- nodes do
        {:ok, _} =
          rpc(n, Horde.Supervisor, :start_link, [[name: TestSup, strategy: :one_for_one]])

        {:ok, _} = rpc(n, Horde.Registry, :start_link, [[name: TestReg, keys: :unique]])
        reg_members = for n <- nodes, do: {TestReg, n}
        :ok = rpc(n, Horde.Cluster, :set_members, [TestReg, reg_members])

        sup_members = for n <- nodes, do: {TestSup, n}
        :ok = rpc(n, Horde.Cluster, :set_members, [TestSup, sup_members])
      end

    [nodes: nodes]
  end

  @tag skip: true
  test "a heal after a netsplit should ensure the process keeps running", %{
    nodes: [n1, n2] = nodes
  } do
    id = "process"
    Schism.heal([n1, n2])

    # given two nodes
    assert {:ok, pid} = rpc(n1, Worker, :start, [id])
    # and a process
    assert :ok = Worker.set_state(pid, "state")

    current_node = node(pid)

    other_node =
      case current_node do
        ^n1 -> n2
        ^n2 -> n1
      end

    assert current_node != other_node

    await_replication(nodes, other_node, id)

    # when a partition is introduced
    Schism.partition([n1])

    new_pid = await_process_on_node(other_node, id)

    # a new process with the same id should be started on the other node
    assert new_pid != pid
    assert node(new_pid) == other_node

    # when the netsplit is healed
    Schism.heal([n1, n2])

    # the old process should be dead
    :ok = await_dead(pid)

    # and only a single process should remain
    assert MapSet.new([true, false]) == MapSet.new([process_alive?(pid), process_alive?(new_pid)])
  end

  defp await_replication(nodes, target, id) do
    for n <- nodes do
      send({TestSup.Crdt, n}, :sync)
      send({TestReg.Crdt, n}, :sync)
    end

    Process.sleep(200)

    do_await_replication(target, id)
  end

  defp do_await_replication(target, id) do
    pid = rpc(target, Horde.Registry, :whereis_name, [{TestReg, id}])

    case pid do
      pid when is_pid(pid) ->
        pid

      x ->
        Process.sleep(200)
        do_await_replication(target, id)
    end
  end

  defp await_process_on_node(target, id) do
    pid = rpc(target, Horde.Registry, :whereis_name, [{TestReg, id}])

    case pid do
      pid when is_pid(pid) ->
        case node(pid) do
          ^target ->
            pid

          _ ->
            nodes = rpc(target, Node, :list, [])

            Logger.info(
              "found #{inspect(pid)} on node: #{inspect(node(pid))}, target #{inspect(node)}, nodes: #{
                inspect(nodes)
              }"
            )

            Process.sleep(200)
            await_process_on_node(target, id)
        end

      _ ->
        Logger.info("didn't find pid")
        Process.sleep(200)
        await_process_on_node(target, id)
    end
  end

  defp rpc(n, m, f, a) do
    :rpc.block_call(n, m, f, a)
  end

  defp await_dead(pid) do
    case process_alive?(pid) do
      false ->
        :ok

      true ->
        Process.sleep(200)
        await_dead(pid)
    end
  end

  defp process_alive?(pid) do
    rpc(node(pid), Process, :alive?, [pid])
  end
end
