defmodule Horde.Registry do
  @moduledoc """
  A distributed process registry that takes advantage of δ-CRDTs.
  """
  import Kernel, except: [send: 2]

  defmodule State do
    @moduledoc false
    defstruct node_id: nil,
              members_pid: nil,
              members: %{},
              processes_pid: nil,
              processes: %{}
  end

  @crdt DeltaCrdt.AWLWWMap

  @doc """
  Child spec to enable easy inclusion into a supervisor:
  supervise([
    [Horde, :node_1]
  ])
  """
  def child_spec(node_id) do
    %{id: node_id, start: {GenServer, :start_link, [__MODULE__, node_id]}}
  end

  @doc """
  Join two hordes into one big horde. Calling this once will inform every node in each horde of every node in the other horde.
  """
  def join_hordes(horde, other_horde) do
    GenServer.cast(horde, {:join_horde, other_horde})
  end

  @doc """
  Remove own node from the hordes (gracefully retire node)
  """
  def leave_hordes(horde) do
    GenServer.cast(horde, :leave_horde)
  end

  @doc "register a process under given name for entire horde"
  def register(horde, name, pid) do
    GenServer.cast(horde, {:register, name, pid})
  end

  def unregister(horde, name) do
    GenServer.cast(horde, {:unregister, name})
  end

  def whereis(search), do: lookup(search)
  def lookup({:via, _, {horde, name}}), do: lookup(horde, name)

  def lookup(horde, name) do
    case GenServer.call(horde, {:lookup, name}) do
      {:ok, pid} -> pid
      _ -> :undefined
    end
  end

  ### Via callbacks

  @doc false
  # @spec register_name({pid, term}, pid) :: :yes | :no
  def register_name({horde, name}, pid) do
    case GenServer.call(horde, {:register, name, pid}) do
      :ok -> :yes
      _ -> :no
    end
  end

  @doc false
  # @spec whereis_name({pid, term}) :: pid | :undefined
  def whereis_name({horde, name}) do
    lookup(horde, name)
  end

  @doc false
  def unregister_name({horde, name}), do: unregister(horde, name)

  @doc false
  def send({horde, name}, msg) do
    case lookup(horde, name) do
      :undefined -> :erlang.error(:badarg, [{horde, name}, msg])
      pid -> Kernel.send(pid, msg)
    end
  end

  @doc """
  Get the members (nodes) of the horde
  """
  def members(horde) do
    GenServer.call(horde, :members)
  end

  @doc """
  Get the process regsitry of the horde
  """
  def processes(horde) do
    GenServer.call(horde, :processes)
  end

  ### GenServer callbacks

  def init(node_id) do
    {:ok, members_pid} = @crdt.start_link({self(), :members_updated})

    {:ok, processes_pid} = @crdt.start_link({self(), :processes_updated})

    GenServer.cast(
      members_pid,
      {:operation, {@crdt, :add, [node_id, {members_pid, processes_pid}]}}
    )

    {:ok,
     %State{
       node_id: node_id,
       members_pid: members_pid,
       processes_pid: processes_pid
     }}
  end

  def handle_cast(
        {:request_to_join_horde, {_other_node_id, other_members_pid}},
        state
      ) do
    Kernel.send(state.members_pid, {:add_neighbour, other_members_pid})
    Kernel.send(state.members_pid, :ship_interval_or_state_to_all)
    {:noreply, state}
  end

  def handle_cast({:join_horde, other_horde}, state) do
    GenServer.cast(other_horde, {:request_to_join_horde, {state.node_id, state.members_pid}})
    {:noreply, state}
  end

  def handle_cast(:leave_horde, state) do
    GenServer.cast(
      state.members_pid,
      {:operation, {@crdt, :remove, [state.node_id]}}
    )

    Kernel.send(state.members_pid, :ship_interval_or_state_to_all)
    {:noreply, state}
  end

  def handle_cast({:register, name, pid}, state) do
    GenServer.cast(
      state.processes_pid,
      {:operation, {@crdt, :add, [name, {pid}]}}
    )

    Kernel.send(state.processes_pid, :ship_interval_or_state_to_all)
    {:noreply, state}
  end

  def handle_cast({:unregister, name}, state) do
    GenServer.cast(
      state.processes_pid,
      {:operation, {@crdt, :remove, [name]}}
    )

    Kernel.send(state.processes_pid, :ship_interval_or_state_to_all)
    {:noreply, state}
  end

  def handle_info(:processes_updated, state) do
    processes = GenServer.call(state.processes_pid, {:read, @crdt})

    {:noreply, %{state | processes: processes}}
  end

  def handle_info(:members_updated, state) do
    members = GenServer.call(state.members_pid, {:read, @crdt})

    member_pids =
      Enum.into(members, MapSet.new(), fn {_key, {members_pid, _processes_pid}} -> members_pid end)

    state_member_pids =
      Enum.into(state.members, MapSet.new(), fn {_node_id, {pid, _processes_pid}} -> pid end)

    # if there are any new pids in `member_pids`
    if MapSet.difference(member_pids, state_member_pids) |> Enum.any?() do
      processes_pids = Enum.into(members, MapSet.new(), fn {_node_id, {_mpid, pid}} -> pid end)
      Kernel.send(state.members_pid, {:add_neighbours, member_pids})
      Kernel.send(state.processes_pid, {:add_neighbours, processes_pids})
      Kernel.send(state.members_pid, :ship_interval_or_state_to_all)
      Kernel.send(state.processes_pid, :ship_interval_or_state_to_all)
    end

    {:noreply, %{state | members: members}}
  end

  def handle_call({:register, name, pid}, _from, state) do
    result =
      GenServer.call(
        state.processes_pid,
        {:operation, {@crdt, :add, [name, {pid}]}}
      )

    Kernel.send(state.processes_pid, :ship_interval_or_state_to_all)
    {:reply, result, state}
  end

  def handle_call(:members, _from, state) do
    {:reply, {:ok, state.members}, state}
  end

  def handle_call(:processes, _from, state) do
    {:reply, {:ok, state.processes}, state}
  end

  def handle_call({:lookup, name}, _from, state) do
    case Map.get(state.processes, name) do
      nil -> {:reply, nil, state}
      {pid} -> {:reply, {:ok, pid}, state}
    end
  end
end
