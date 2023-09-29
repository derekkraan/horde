defmodule NetworkPartitionTest do
  use ExUnit.Case

  setup do
    nodes = LocalCluster.start_nodes("cluster#{:erlang.unique_integer()}", 2)

    for n <- nodes do
      :rpc.call(n, Application, :ensure_all_started, [:test_app])
    end

    [nodes: nodes]
  end

  test "recovers as expected in case of network partition", %{nodes: [n1, n2] = nodes} do
    assert {:ok, _pid1} =
             Horde.DynamicSupervisor.start_child(
               {TestSup, n1},
               {IgnoreWorker, {:via, Horde.Registry, {TestReg, IgnoreWorker}}}
             )

    assert {:ok, _pid2} =
             Horde.DynamicSupervisor.start_child(
               {TestSup, n2},
               {IgnoreWorker, {:via, Horde.Registry, {TestReg, IgnoreWorker}}}
             )

    reg_members = for n <- nodes, do: {TestReg, n}
    sup_members = for n <- nodes, do: {TestSup, n}

    for n <- nodes do
      :ok = :rpc.call(n, Horde.Cluster, :set_members, [TestReg, reg_members])
      :ok = :rpc.call(n, Horde.Cluster, :set_members, [TestSup, sup_members])
    end

    Schism.partition([n1])
    Schism.partition([n2])

    Process.sleep(100)

    Schism.heal([n1, n2])

    Process.sleep(100)

    assert [{_, pid, _, _}] = Horde.DynamicSupervisor.which_children({TestSup, n1})
    assert [{_, ^pid, _, _}] = Horde.DynamicSupervisor.which_children({TestSup, n2})

    assert true = :rpc.call(node(pid), Process, :alive?, [pid])
  end

  test "recovers as expected in case of node stopping", %{nodes: [n1, n2] = nodes} do
    assert {:ok, _pid1} =
             Horde.DynamicSupervisor.start_child(
               {TestSup, n1},
               {IgnoreWorker, {:via, Horde.Registry, {TestReg, IgnoreWorker}}}
             )

    assert {:ok, _pid2} =
             Horde.DynamicSupervisor.start_child(
               {TestSup, n2},
               {IgnoreWorker, {:via, Horde.Registry, {TestReg, IgnoreWorker}}}
             )

    require Logger
    Logger.info("stitching together cluster")

    reg_members = for n <- nodes, do: {TestReg, n}
    sup_members = for n <- nodes, do: {TestSup, n}

    for n <- nodes do
      :ok = :rpc.call(n, Horde.Cluster, :set_members, [TestReg, reg_members])
      :ok = :rpc.call(n, Horde.Cluster, :set_members, [TestSup, sup_members])
    end

    Process.sleep(100)

    Logger.info("stopping #{n2}")
    LocalCluster.stop_nodes([n2])

    Process.sleep(100)

    assert [{_, pid, _, _}] = Horde.DynamicSupervisor.which_children({TestSup, n1})

    assert true = :rpc.call(node(pid), Process, :alive?, [pid])
  end
end
