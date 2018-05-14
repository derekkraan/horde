defmodule Horde do
  @moduledoc """
  Horde is a distributed process registry that takes advantage of Delta-CRDTs.
  """

  alias DeltaCrdt.{CausalCrdt, AddWinsFirstWriteWinsMap, ObservedRemoveMap}

  defmodule State do
    defstruct node_id: nil,
              members_pid: nil,
              members: %{}
  end

  def child_spec(node_id) do
    %{id: node_id, start: {__MODULE__, :start_link, [node_id]}}
  end

  def start_link(node_id) do
    GenServer.start_link(__MODULE__, node_id)
  end

  def join_hordes(horde, other_horde) do
    GenServer.cast(horde, {:join_horde, other_horde})
  end

  def members(horde) do
    GenServer.call(horde, :members)
  end

  ### GenServer callbacks

  def init(node_id) do
    {:ok, members_pid} = CausalCrdt.start_link(%ObservedRemoveMap{}, {self(), :members_updated})

    GenServer.cast(
      members_pid,
      {:operation, {AddWinsFirstWriteWinsMap, :add, [node_id, {members_pid}]}}
    )

    {:ok,
     %State{
       node_id: node_id,
       members_pid: members_pid,
       members: %{node_id => {members_pid}}
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

  def handle_info(:members_updated, state) do
    members = GenServer.call(state.members_pid, {:read, AddWinsFirstWriteWinsMap})

    member_pids =
      Enum.map(members, fn {_key, {pid}} -> pid end)
      |> Enum.into(MapSet.new())

    state_member_pids =
      Enum.map(state.members, fn {_node_id, {pid}} -> pid end) |> Enum.into(MapSet.new())

    if !MapSet.equal?(member_pids, state_member_pids) do
      send(state.members_pid, {:add_neighbours, member_pids})
      send(state.members_pid, :ship_interval_or_state_to_all)
    end

    {:noreply, %{state | members: members}}
  end

  def handle_cast({:join_horde, other_horde}, state) do
    GenServer.cast(other_horde, {:request_to_join_horde, {state.node_id, state.members_pid}})
    {:noreply, state}
  end

  def handle_call(:members, _from, state) do
    {:reply, {:ok, state.members}, state}
  end
end
