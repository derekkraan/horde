defmodule LocalClusterHelper do
  def start(m, f, a) do
    :erlang.apply(m, f, a)

    receive do
    end
  end

  def send_msg(pid, msg) do
    fn -> send(pid, msg) end
  end

  def expected_distribution(cspecs, members) do 
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

      Map.put(acc, Map.delete(child_spec, [:id]), new_sup_name)
    end)
  end

  def expected_distribution_for(cspecs, members, sup_name) do
    expected_distribution(cspecs, members)
    |> Map.to_list()
    |> Enum.filter(fn {_cspec, name} ->
      Kernel.match?(^name, sup_name)
    end)
    |> Enum.map(fn {child, _sup_name} ->
      child
    end)
  end

  def running_children(name) do 
      sup_state =
        Task.async(fn ->
          LocalClusterHelper.await_members_alive(name)
        end)
        |> Task.await()

      sup_state.processes_by_id
      |> Enum.filter(fn {_id, {{sup_name, _}, _cspec, _pid}} ->
        Kernel.match?(^name, sup_name)
      end)
  end

  def supervisor_has_children?(name, children) do 
      running_children(name)
      |> Enum.map(fn {_, {_, cspec, _}} ->
        cspec = Map.delete(cspec, [:id])
        Enum.any?(children, fn child ->
          child == cspec
        end)
      end)
      |> Enum.all?()
  end

  def await_members_alive(sup_name) do
    # get members_info from the DyanamicSupervisorImpl n1 state
    ds_state = :sys.get_state(Process.whereis(sup_name))

    # check that state is :alive for all nodes
    all_alive =
      ds_state.members_info
      |> Map.values()
      |> Enum.all?(fn mem ->
        mem.status == :alive
      end)

    case all_alive do
      false ->
        # sleep 100ms and try again
        :timer.sleep(100)
        await_members_alive(sup_name)

      true ->
        ds_state
    end
  end
end

defmodule EchoServer do
  def start_link(pid) do
    GenServer.start_link(__MODULE__, pid)
  end

  # def via_tuple do
  #   {:via, Horde.Registry, {:horde_registry, "echo"}}
  # end

  def init(pid) do
    send(self(), :do_send)
    {:ok, pid}
  end

  def handle_info(:do_send, pid) do
    send(pid, {node(), :hello_echo_server})
    Process.send_after(self(), :do_send, 1_000)
    {:noreply, pid}
  end
end

defmodule RebalanceTestServer do
  use GenServer

  def start_link({name, ppid}) do
    GenServer.start_link(__MODULE__, ppid, name: name)
  end

  @impl true
  def init(ppid) do
    Process.flag(:trap_exit, true)
    {:ok, ppid}
  end

  @impl true
  def terminate(reason, ppid) do 
    send(ppid, {:shutdown, reason})
    Process.exit(self(), :kill)
  end
end
