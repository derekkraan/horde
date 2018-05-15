defmodule Horde do
  @moduledoc """
  Horde is a distributed process registry that takes advantage of Delta-CRDTs.
  """

  alias DeltaCrdt.{CausalCrdt, AddWinsFirstWriteWinsMap, ObservedRemoveMap}

  defmodule State do
    @moduledoc false
    defstruct node_id: nil,
              members_pid: nil,
              members: %{},
              processes_pid: nil,
              processes: %{}
  end

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
  Remove a node from the hordes
  """
  def leave_hordes(horde)

  @doc "register a process under given name for entire horde"
  def register(horde, name, pid) do
    GenServer.cast(horde, {:register, name, pid})
  end

  def unregister(name) do

  end


  def lookup(horde, name) do

  end

  def start_handoff(name) do

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
    {:ok, members_pid} = CausalCrdt.start_link(%ObservedRemoveMap{}, {self(), :members_updated})
    {:ok, processes_pid} = CausalCrdt.start_link(%ObservedRemoveMap{}, {self(), :processes_updated})

    GenServer.cast(
      members_pid,
      {:operation, {AddWinsFirstWriteWinsMap, :add, [node_id, {members_pid, processes_pid}]}}
    )

    {:ok,
     %State{
       node_id: node_id,
       members_pid: members_pid,
       processes_pid: processes_pid
     }}
  end

  def handle_cast(
        {:request_to_join_horde, {other_node_id, other_members_pid}},
        state
      ) do
    send(state.members_pid, {:add_neighbour, other_members_pid})
    send(state.members_pid, :ship_interval_or_state_to_all)
    {:noreply, state}
  end

  def handle_cast({:join_horde, other_horde}, state) do
    GenServer.cast(other_horde, {:request_to_join_horde, {state.node_id, state.members_pid}})
    {:noreply, state}
  end

  def handle_cast({:register, name, pid}, state) do
    GenServer.cast(
      state.processes_pid,
      {:operation, {AddWinsFirstWriteWinsMap, :add, [name, {pid}]}}
    )
    send(state.processes_pid, :ship_interval_or_state_to_all)
    {:noreply, state}
  end

  def handle_info(:processes_updated, state) do
    processes = GenServer.call(state.processes_pid, {:read, AddWinsFirstWriteWinsMap})

    processes_pids =
      Enum.into(processes, MapSet.new(), fn {_name, {pid}} -> pid end)

    state_processes_pids =
      Enum.into(state.processes, MapSet.new(), fn {_name, {pid}} -> pid end)

    if MapSet.difference(processes_pids, state_processes_pids) |> Enum.any?() do
      send(state.processes_pid, {:add_neighbours, processes_pids})
      send(state.processes_pid, :ship_interval_or_state_to_all)
    end

    {:noreply, %{state | processes: processes}}
  end

    def handle_info(:members_updated, state) do
    members = GenServer.call(state.members_pid, {:read, AddWinsFirstWriteWinsMap})

    member_pids =
      Enum.map(members, fn {_key, {members_pid, _processes_pid}} -> members_pid end)
      |> Enum.into(MapSet.new())

    state_member_pids =
      Enum.map(state.members, fn {_node_id, {pid, _processes_pid}} -> pid end) |> Enum.into(MapSet.new())

    # if there are any new pids in `member_pids`
    if MapSet.difference(member_pids, state_member_pids) |> Enum.any?() do
      processes_pids = Enum.into(members, MapSet.new(), fn {_node_id, {_mpid, pid}} -> pid end)
      send(state.members_pid, {:add_neighbours, member_pids})
      send(state.processes_pid, {:add_neighbours, processes_pids})
      send(state.members_pid, :ship_interval_or_state_to_all)
      send(state.processes_pid, :ship_interval_or_state_to_all)
    end

    {:noreply, %{state | members: members}}
  end

  def handle_call(:members, _from, state) do
    {:reply, {:ok, state.members}, state}
  end

  def handle_call(:processes, _from, state) do
    {:reply, {:ok, state.processes}, state}
  end

end
