defmodule DynamicSupervisorTest do
  require Logger
  use ExUnit.Case

  setup do
    n1 = :"horde_#{:rand.uniform(100_000_000)}"
    n2 = :"horde_#{:rand.uniform(100_000_000)}"
    n3 = :"horde_#{:rand.uniform(100_000_000)}"

    {:ok, horde_1_sup_pid} =
      Horde.DynamicSupervisor.start_link(
        name: n1,
        strategy: :one_for_one,
        delta_crdt_options: [sync_interval: 20]
      )

    {:ok, _} =
      Horde.DynamicSupervisor.start_link(
        name: n2,
        strategy: :one_for_one,
        delta_crdt_options: [sync_interval: 20]
      )

    {:ok, _} =
      Horde.DynamicSupervisor.start_link(
        name: n3,
        strategy: :one_for_one,
        delta_crdt_options: [sync_interval: 20]
      )

    Horde.Cluster.set_members(n1, [n1, n2, n3])

    # give the processes a couple ms to sync up
    Process.sleep(100)

    pid = self()

    task_def = %{
      id: "proc_1",
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

  @tag timeout: 120_000
  test "many transient processes", context do
    test_pid = self()

    number = 1000

    Enum.each(1..number, fn x ->
      Enum.random([context.horde_1, context.horde_2, context.horde_3])
      |> Horde.DynamicSupervisor.start_child(%{
        id: x,
        restart: :transient,
        start: {Task, :start_link, [fn -> send(test_pid, x) end]}
      })
    end)

    Enum.each(1..number, fn x ->
      assert_receive ^x
    end)

    Enum.each(1..number, fn x ->
      refute_receive ^x, 10
    end)
  end

  describe "module-based DynamicSupervisor" do
    test "can use `init` function to dynamically fetch configuration" do
      {:ok, _} = TestSupervisor1.start_link([], name: :init_sup_test_1)
      {:ok, _} = TestSupervisor2.start_link([], name: :init_sup_test_2)
      members = Horde.Cluster.members(:init_sup_test_1)
      assert 2 = Enum.count(members)
    end

    test "can use `child_spec` function to override defaults from Horde.DynamicSupervisor" do
      child_spec = %{
        id: 123,
        start:
          {TestSupervisor3, :start_link,
           [
             [
               custom_id: 123,
               name: :init_sup_test_3,
               strategy: :one_for_one
             ]
           ]},
        restart: :transient,
        type: :supervisor
      }

      assert ^child_spec =
               TestSupervisor3.child_spec(
                 custom_id: 123,
                 name: :init_sup_test_3,
                 strategy: :one_for_one
               )
    end
  end

  describe ".start_child/2" do
    test "starts a process", context do
      assert {:ok, pid} = Horde.DynamicSupervisor.start_child(context.horde_1, context.task_def)

      assert_receive {:process_started, ^pid}
    end

    test "does not return error when starting same process twice", context do
      assert {:ok, pid} = Horde.DynamicSupervisor.start_child(context.horde_1, context.task_def)

      assert is_pid(pid)

      assert {:ok, other_pid} =
               Horde.DynamicSupervisor.start_child(context.horde_1, context.task_def)

      assert pid != other_pid
    end

    test "starts a process with id that doesn't implement String.Chars", context do
      task_def = %{context.task_def | id: {:proc2, "string"}}

      assert {:ok, pid} = Horde.DynamicSupervisor.start_child(context.horde_1, task_def)

      assert_receive {:process_started, ^pid}
    end

    test "failed process is restarted", context do
      Horde.DynamicSupervisor.start_child(context.horde_1, context.task_def)
      assert_receive {:process_started, pid}
      Process.exit(pid, :kill)
      assert_receive {:process_started, _pid}
    end

    test "processes are started on different nodes", context do
      pid = self()

      make_task = fn x ->
        %{
          id: "proc_1",
          start:
            {Task, :start_link,
             [
               fn ->
                 send(pid, {:process_started, x, self()})
                 Process.sleep(100_000)
               end
             ]},
          type: :worker,
          shutdown: 10
        }
      end

      Enum.each(1..10, fn x ->
        Horde.DynamicSupervisor.start_child(
          context.horde_1,
          make_task.(x)
        )
      end)

      supervisor_pids =
        Enum.map(1..10, fn x ->
          assert_receive {:process_started, x, task_pid}
          {:links, [supervisor_pid]} = task_pid |> Process.info(:links)
          supervisor_pid
        end)
        |> Enum.uniq()

      assert Enum.uniq(supervisor_pids) |> Enum.count() > 1
    end
  end

  describe ".which_children/1" do
    test "collects results from all horde nodes", context do
      Horde.DynamicSupervisor.start_child(context.horde_1, %{context.task_def | id: :proc_1})
      Horde.DynamicSupervisor.start_child(context.horde_1, %{context.task_def | id: :proc_2})

      assert [{:undefined, _, _, _}, {:undefined, _, _, _}] =
               Horde.DynamicSupervisor.which_children(context.horde_1)
    end
  end

  describe ".count_children/1" do
    test "counts children", context do
      1..10
      |> Enum.each(fn x ->
        Horde.DynamicSupervisor.start_child(
          context.horde_1,
          Map.put(context.task_def, :id, :"proc_#{x}")
        )
      end)

      Process.sleep(200)

      assert %{workers: 10} = Horde.DynamicSupervisor.count_children(context.horde_1)
    end
  end

  describe ".terminate_child/2" do
    test "terminates the child", context do
      {:ok, pid} =
        Horde.DynamicSupervisor.start_child(
          context.horde_1,
          Map.put(context.task_def, :id, "kill_me")
        )

      Process.sleep(200)

      :ok = Horde.DynamicSupervisor.terminate_child(context.horde_1, pid)
    end
  end

  describe "failover" do
    test "failed horde's processes are taken over by other hordes", context do
      max = 200

      1..max
      |> Enum.each(fn x ->
        Horde.DynamicSupervisor.start_child(
          context.horde_1,
          Map.put(context.task_def, :id, :"proc_#{x}")
        )
      end)

      assert %{workers: ^max} = Horde.DynamicSupervisor.count_children(context.horde_1)

      Process.sleep(1000)

      assert %{workers: ^max} = Horde.DynamicSupervisor.count_children(context.horde_2)

      Process.unlink(context.horde_1_sup_pid)
      Process.exit(context.horde_1_sup_pid, :kill)

      %{workers: workers} = Horde.DynamicSupervisor.count_children(context.horde_2)
      assert workers <= max

      Process.sleep(2000)

      assert %{workers: ^max} = Horde.DynamicSupervisor.count_children(context.horde_2)
    end
  end

  describe ".stop/3" do
    test "stopping a node causes supervised processes to shut down", context do
      max = 200

      1..max
      |> Enum.each(fn x ->
        Horde.DynamicSupervisor.start_child(
          context.horde_1,
          Map.put(context.task_def, :id, :"proc_#{x}")
        )
      end)

      Process.sleep(1000)

      assert %{workers: ^max} = Horde.DynamicSupervisor.count_children(context.horde_1)

      :ok = Horde.DynamicSupervisor.stop(context.horde_1)

      assert Horde.DynamicSupervisor.count_children(context.horde_2).workers <= max
    end
  end

  describe "graceful shutdown" do
    test "stopping a node moves processes over when they are ready" do
      {:ok, _} =
        Horde.DynamicSupervisor.start_link(
          name: :horde_1_graceful,
          strategy: :one_for_one,
          delta_crdt_options: [sync_interval: 20]
        )

      {:ok, _} =
        Horde.DynamicSupervisor.start_link(
          name: :horde_2_graceful,
          strategy: :one_for_one,
          delta_crdt_options: [sync_interval: 20]
        )

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

      Horde.DynamicSupervisor.start_child(:horde_1_graceful, %{
        id: :fast,
        start: {GenServer, :start_link, [TerminationDelay, {500, pid}]},
        shutdown: 2000
      })

      Horde.DynamicSupervisor.start_child(:horde_1_graceful, %{
        id: :slow,
        start: {GenServer, :start_link, [TerminationDelay, {5000, pid}]},
        shutdown: 10000
      })

      Horde.Cluster.set_members(:horde_1_graceful, [:horde_1_graceful, :horde_2_graceful])

      Process.sleep(500)

      assert_receive {:starting, 500}, 200
      assert_receive {:starting, 5000}, 200

      Task.start_link(fn ->
        Horde.DynamicSupervisor.stop(:horde_1_graceful)
      end)

      assert_receive {:stopping, 500}, 100
      assert_receive {:stopping, 5000}, 100

      Process.sleep(2000)

      assert_receive {:starting, 500}, 100
      refute_receive {:starting, 5000}, 100

      Process.sleep(5000)
      assert_receive {:starting, 5000}, 100
    end
  end

  describe "temporary and transient processes" do
    test "temporary task gets removed from supervisor after exit" do
      test_function = fn -> Process.exit(self(), :kill) end

      child_spec = Task.child_spec(test_function)

      {:ok, _} =
        Horde.DynamicSupervisor.start_link(
          name: :horde_transient,
          strategy: :one_for_one,
          delta_crdt_options: [sync_interval: 20]
        )

      Horde.DynamicSupervisor.start_child(:horde_transient, child_spec)

      Process.sleep(50)

      assert :sys.get_state(:horde_transient).processes_by_id == %{}
    end

    test "transient process get removed from supervisor after exit" do
      test_function = fn -> Process.exit(self(), :normal) end

      child_spec = %{Task.child_spec(test_function) | restart: :transient}

      {:ok, _} =
        Horde.DynamicSupervisor.start_link(
          name: :horde_transient,
          strategy: :one_for_one,
          delta_crdt_options: [sync_interval: 20]
        )

      Horde.DynamicSupervisor.start_child(:horde_transient, child_spec)

      Process.sleep(200)

      assert :sys.get_state(:horde_transient).processes_by_id == %{}
    end

    test "transient process does not get removed from supervisor after failed exit" do
      test_function = fn -> Process.exit(self(), :error) end

      child_spec = %{Task.child_spec(test_function) | restart: :transient}

      {:ok, _} =
        Horde.DynamicSupervisor.start_link(
          name: :horde_transient,
          strategy: :one_for_one,
          delta_crdt_options: [sync_interval: 20]
        )

      Horde.DynamicSupervisor.start_child(:horde_transient, child_spec)

      processes = :sys.get_state(:horde_transient).processes_by_id
      assert Enum.count(processes) == 1
    end
  end

  describe "stress test" do
    test "registering a lot of workers doesn't cause an exit", context do
      max = 2000

      1..max
      |> Enum.each(fn x ->
        Horde.DynamicSupervisor.start_child(
          context.horde_1,
          Map.put(context.task_def, :id, :"proc_#{x}")
        )
      end)

      assert %{workers: ^max} = Horde.DynamicSupervisor.count_children(context.horde_1)
    end
  end

  defmodule IgnoringGenServer do
    use GenServer

    def start_link() do
      GenServer.start_link(__MODULE__, [])
    end

    def init(_) do
      :ignore
    end
  end

  test "can handle :ignore", context do
    spec = %{
      id: :test,
      start: {IgnoringGenServer, :start_link, []}
    }

    assert :ignore = Horde.DynamicSupervisor.start_child(context.horde_1, spec)
  end

  test "wait_for_quorum/2" do
    {:ok, _} =
      Horde.DynamicSupervisor.start_link(
        name: :horde_quorum_1,
        strategy: :one_for_one,
        distribution_strategy: Horde.UniformQuorumDistribution,
        members: [:horde_quorum_1, :horde_quorum_2, :horde_quorum_3],
        delta_crdt_options: [sync_interval: 20]
      )

    catch_exit(Horde.DynamicSupervisor.wait_for_quorum(:horde_quorum_1, 100))

    {:ok, _} =
      Horde.DynamicSupervisor.start_link(
        name: :horde_quorum_2,
        strategy: :one_for_one,
        distribution_strategy: Horde.UniformQuorumDistribution,
        members: [:horde_quorum_1, :horde_quorum_2, :horde_quorum_3],
        delta_crdt_options: [sync_interval: 20]
      )

    assert :ok == Horde.DynamicSupervisor.wait_for_quorum(:horde_quorum_1, 1000)
    assert :ok == Horde.DynamicSupervisor.wait_for_quorum(:horde_quorum_2, 1000)
  end

  test "redistribute/1" do
    n1 = :horde_redistribute_1
    n2 = :horde_redistribute_2

    members = [{n1, Node.self()}, {n2, Node.self()}]

    # Spawn one supervisor and add processes to it, then spawn another and redistribute
    # the processes between the two.
    {:ok, _} =
      Horde.DynamicSupervisor.start_link(
        name: n1,
        strategy: :one_for_one,
        delta_crdt_options: [sync_interval: 20],
        members: members
      )

    defmodule RebalanceTestServer do
      use GenServer

      def start_link(opts) do
        GenServer.start_link(__MODULE__, nil, name: opts[:name])
      end

      @impl true
      def init(_) do
        {:ok, nil}
      end
    end

    # Start 5 child processes with randomized names
    cspecs =
      0..9
      |> Enum.map(fn _ ->
        name = :"child_#{:rand.uniform(100_000_000)}"

        %{
          id: name,
          start: {RebalanceTestServer, :start_link, [[name: name]]}
        }
      end)

    cspecs
    |> Enum.each(fn spec ->
      assert Kernel.match?({:ok, _}, Horde.DynamicSupervisor.start_child(n1, spec))
    end)

    expected =
      cspecs
      |> Enum.reduce(%{}, fn child_spec, acc ->
        # precalculate which processes should end up on which nodes 
        identifier = :erlang.phash2(Map.drop(child_spec, [:id]))

        ds_members = members 
         |> Enum.map(fn (node) -> 
            %Horde.DynamicSupervisor.Member{
              name: node,
              status: :alive
            }
          end) 

        {:ok, %Horde.DynamicSupervisor.Member{name: {new_sup_name, _}}} =
          Horde.UniformDistribution.choose_node(identifier, ds_members)

        Map.put(acc, child_spec.id, new_sup_name)
      end)

    :timer.sleep(100) # wait for n1 to spin up
    n1_state = :sys.get_state(Process.whereis(n1))

    n2_pnames =
      expected
      |> Map.to_list()
      |> Enum.filter(fn {cid, sup_name} ->
        sup_name == n2
      end)
      |> Enum.map(fn {cid, sup_name} ->
        with %{processes_by_id: processes_by_id} <- n1_state,
             {_, {_, %{start: {_, _, [[name: pname]]}}, _}} <- Map.get(processes_by_id, cid) do
          pname
        end
      end)

    # Now spin up the 2nd DynamicSupervisor
    {:ok, _} =
      Horde.DynamicSupervisor.start_link(
        name: n2,
        strategy: :one_for_one,
        delta_crdt_options: [sync_interval: 20],
        members: members
      )

    # redistribution now happens automatically :) but you could trigger it manually like this:
    # :ok = Horde.DynamicSupervisor.redistribute(n1)

    n2_state =
      Task.async(fn ->
        LocalClusterHelper.await_members_alive(n2)
      end)
      |> Task.await()

    #ensure that all nodes that should end up on n2 do actually end up there.
    all_ok =
      n2_state.processes_by_id
      |> Enum.filter(fn {_, {{sup_name, _}, _, _}} ->
        sup_name == n2
      end)
      |> Enum.map(fn {_, {_, %{start: {_, _, [[name: pname]]}}, _}} ->
        Enum.any?(n2_pnames, fn n2pn ->
          n2pn == pname
        end)
      end)
      |> Enum.all?()

    assert all_ok
  end
end
