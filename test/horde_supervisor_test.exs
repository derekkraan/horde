defmodule HordeSupervisorTest do
  use ExUnit.Case, async: true

  setup do
    {:ok, horde_1} = Horde.Supervisor.start_link([], node_id: :horde_1, strategy: :one_for_one)
    {:ok, horde_2} = Horde.Supervisor.start_link([], node_id: :horde_2, strategy: :one_for_one)
    {:ok, horde_3} = Horde.Supervisor.start_link([], node_id: :horde_3, strategy: :one_for_one)

    Horde.Cluster.join_hordes(horde_1, horde_2)
    Horde.Cluster.join_hordes(horde_3, horde_2)

    # give the processes a couple ms to sync up
    Process.sleep(20)

    pid = self()

    task_def = %{
      id: :proc_1,
      start:
        {Task, :start_link,
         [
           fn ->
             send(pid, {:process_started, self()})
             Process.sleep(1000)
           end
         ]},
      type: :worker,
      restart: :transient
    }

    [
      horde_1: horde_1,
      horde_2: horde_2,
      horde_3: horde_3,
      task_def: task_def
    ]
  end

  describe ".start_child/2" do
    test "starts a process", context do
      assert {:ok, pid} = Horde.Supervisor.start_child(context.horde_1, context.task_def)

      assert_receive {:process_started, ^pid}
    end

    test "failed process is restarted", context do
      Horde.Supervisor.start_child(context.horde_1, context.task_def)
      assert_receive {:process_started, pid}
      Process.exit(pid, :kill)
      assert_receive {:process_started, _pid}
    end

    test "processes are started on different nodes", context do
      1..10
      |> Enum.each(fn x ->
        Horde.Supervisor.start_child(
          context.horde_1,
          Map.put(context.task_def, :id, :"proc_#{x}")
        )
      end)

      supervisor_pids =
        1..10
        |> Enum.map(fn _ ->
          assert_receive {:process_started, task_pid}
          {:links, [supervisor_pid]} = task_pid |> Process.info(:links)
          supervisor_pid
        end)
        |> Enum.uniq()

      assert Enum.uniq(supervisor_pids) |> Enum.count() > 1
    end
  end

  describe ".restart_child/2" do
    test "restarts a process", context do
      Horde.Supervisor.start_child(context.horde_1, context.task_def)
      assert_receive({:process_started, _pid})
      Process.sleep(1000)
      Horde.Supervisor.restart_child(context.horde_1, context.task_def.id)
      assert_receive({:process_started, _pid})
    end
  end

  describe ".which_children/1" do
    test "collects results from all horde nodes", context do
      Horde.Supervisor.start_child(context.horde_1, %{context.task_def | id: :proc_1})
      Horde.Supervisor.start_child(context.horde_1, %{context.task_def | id: :proc_2})
      assert 2 = Horde.Supervisor.which_children(context.horde_1) |> Enum.count()
    end
  end

  describe ".count_children/1" do
    test "counts children", context do
      1..10
      |> Enum.each(fn x ->
        Horde.Supervisor.start_child(
          context.horde_1,
          Map.put(context.task_def, :id, :"proc_#{x}")
        )
      end)

      assert %{workers: 10} = Horde.Supervisor.count_children(context.horde_1)
    end
  end

  describe "failover" do
    test "failed horde's processes are taken over by other hordes", context do
      max = 200

      1..max
      |> Enum.each(fn x ->
        Horde.Supervisor.start_child(
          context.horde_1,
          Map.put(context.task_def, :id, :"proc_#{x}")
        )
      end)

      Process.sleep(2000)

      Process.unlink(context.horde_2)
      Process.exit(context.horde_2, :kill)

      %{workers: workers} = Horde.Supervisor.count_children(context.horde_1)
      assert workers < max

      Process.sleep(2000)

      assert %{workers: ^max} = Horde.Supervisor.count_children(context.horde_1)
    end

    # test "netsplit"
  end

  describe ".leave_horde/1" do
    test "removing a node from a horde causes supervised processes to shut down", context do
      max = 200

      1..max
      |> Enum.each(fn x ->
        Horde.Supervisor.start_child(
          context.horde_1,
          Map.put(context.task_def, :id, :"proc_#{x}")
        )
      end)

      Process.sleep(2000)

      Horde.Cluster.leave_hordes(context.horde_1)

      Process.sleep(5000)

      assert %{workers: ^max} = Horde.Supervisor.count_children(context.horde_2)
    end
  end

  describe "stress test" do
    test "registering a lot of workers doesn't cause an exit", context do
      max = 20_000

      1..max
      |> Enum.each(fn x ->
        Horde.Supervisor.start_child(
          context.horde_1,
          Map.put(context.task_def, :id, :"proc_#{x}")
        )
      end)

      assert %{workers: ^max} = Horde.Supervisor.count_children(context.horde_1)
    end
  end
end
