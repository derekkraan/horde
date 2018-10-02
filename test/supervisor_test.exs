defmodule SupervisorTest do
  require Logger
  use ExUnit.Case, async: false

  setup do
    n1 = :"horde_#{:rand.uniform(100_000_000)}"
    n2 = :"horde_#{:rand.uniform(100_000_000)}"
    n3 = :"horde_#{:rand.uniform(100_000_000)}"
    {:ok, horde_1_sup_pid} = Horde.Supervisor.start_link(name: n1, strategy: :one_for_one)
    {:ok, _} = Horde.Supervisor.start_link(name: n2, strategy: :one_for_one)
    {:ok, _} = Horde.Supervisor.start_link(name: n3, strategy: :one_for_one)

    Horde.Cluster.join_hordes(n1, n2)
    Horde.Cluster.join_hordes(n2, n3)

    # give the processes a couple ms to sync up
    Process.sleep(100)

    pid = self()

    task_def = %{
      id: :proc_1,
      start:
        {Task, :start_link,
         [
           fn ->
             send(pid, {:process_started, self()})
             Process.sleep(100_000)
           end
         ]},
      type: :worker,
      shutdown: 10
    }

    [
      horde_1: n1,
      horde_2: n2,
      horde_3: n3,
      horde_1_sup_pid: horde_1_sup_pid,
      task_def: task_def
    ]
  end

  describe ".start_child/2" do
    test "starts a process", context do
      assert {:ok, pid} = Horde.Supervisor.start_child(context.horde_1, context.task_def)

      assert_receive {:process_started, ^pid}
    end

    test "starts a process with id that doesn't implement String.Chars", context do
      task_def = %{context.task_def | id: {:proc2, "string"}}

      assert {:ok, pid} = Horde.Supervisor.start_child(context.horde_1, task_def)

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

      Process.sleep(100)

      assert %{workers: 10} = Horde.Supervisor.count_children(context.horde_1)
    end
  end

  describe ".terminate_child/2" do
    test "terminates the child", context do
      Horde.Supervisor.start_child(
        context.horde_1,
        Map.put(context.task_def, :id, "kill_me")
      )

      :ok = Horde.Supervisor.terminate_child(context.horde_1, "kill_me")
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

      assert %{workers: ^max} = Horde.Supervisor.count_children(context.horde_1)

      Process.sleep(1000)

      assert %{workers: ^max} = Horde.Supervisor.count_children(context.horde_2)

      Process.unlink(context.horde_1_sup_pid)
      Process.exit(context.horde_1_sup_pid, :kill)

      %{workers: workers} = Horde.Supervisor.count_children(context.horde_2)
      assert workers < max

      Process.sleep(1000)

      assert %{workers: ^max} = Horde.Supervisor.count_children(context.horde_2)
    end
  end

  describe ".stop/3" do
    test "stopping a node causes supervised processes to shut down", context do
      max = 200

      1..max
      |> Enum.each(fn x ->
        Horde.Supervisor.start_child(
          context.horde_1,
          Map.put(context.task_def, :id, :"proc_#{x}")
        )
      end)

      Process.sleep(1000)

      assert %{workers: ^max} = Horde.Supervisor.count_children(context.horde_1)

      Horde.Supervisor.stop(context.horde_1)

      Process.sleep(10000)

      assert %{workers: ^max} = Horde.Supervisor.count_children(context.horde_2)
    end
  end

  describe "graceful shutdown" do
    test "stopping a node moves processes over as soon as they are ready" do
      {:ok, _} = Horde.Supervisor.start_link(name: :horde_1_graceful, strategy: :one_for_one)
      {:ok, _} = Horde.Supervisor.start_link(name: :horde_2_graceful, strategy: :one_for_one)

      defmodule TerminationDelay do
        use GenServer

        def init({timeout, pid}) do
          Process.flag(:trap_exit, true)
          send(pid, {:starting, timeout})
          {:ok, {timeout, pid}}
        end

        def terminate(_reason, {timeout, pid}) do
          send(pid, {:stopping, timeout})
          Process.sleep(timeout)
        end
      end

      pid = self()

      Horde.Supervisor.start_child(:horde_1_graceful, %{
        id: :fast,
        start: {GenServer, :start_link, [TerminationDelay, {500, pid}]},
        shutdown: 2000
      })

      Horde.Supervisor.start_child(:horde_1_graceful, %{
        id: :slow,
        start: {GenServer, :start_link, [TerminationDelay, {5000, pid}]},
        shutdown: 10000
      })

      Horde.Cluster.join_hordes(:horde_1_graceful, :horde_2_graceful)

      Process.sleep(500)

      assert_receive {:starting, 500}, 200
      assert_receive {:starting, 5000}, 200

      Task.start_link(fn -> Horde.Supervisor.stop(:horde_1_graceful) end)

      assert_receive {:stopping, 500}, 100
      assert_receive {:stopping, 5000}

      Process.sleep(2000)

      assert_received {:starting, 500}
      refute_received {:starting, 5000}

      Process.sleep(5000)
      assert_received {:starting, 5000}
    end
  end

  describe "stress test" do
    test "joining hordes dedups processes" do
      {:ok, _} = Horde.Supervisor.start_link(name: :horde_1_dedup, strategy: :one_for_one)
      {:ok, _} = Horde.Supervisor.start_link(name: :horde_2_dedup, strategy: :one_for_one)

      pid = self()

      Horde.Supervisor.start_child(:horde_1_dedup, %{
        id: :foo,
        start:
          {Task, :start_link,
           [
             fn ->
               send(pid, :twice)
               Process.sleep(1000)
               send(pid, :just_once)
               Process.sleep(999_999)
             end
           ]}
      })

      Horde.Supervisor.start_child(:horde_2_dedup, %{
        id: :foo,
        start:
          {Task, :start_link,
           [
             fn ->
               send(pid, :twice)
               Process.sleep(1000)
               send(pid, :just_once)
               Process.sleep(999_999)
             end
           ]}
      })

      Horde.Cluster.join_hordes(:horde_1_dedup, :horde_2_dedup)

      assert_receive :twice, 2000
      assert_receive :twice, 2000
      refute_receive :twice, 2000
      assert_receive :just_once, 2000
      refute_receive :just_once, 2000
    end

    test "registering a lot of workers doesn't cause an exit", context do
      max = 2000

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
