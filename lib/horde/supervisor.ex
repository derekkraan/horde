defmodule Horde.Supervisor do
  use GenServer

  # 60s
  @long_time 60_000

  alias DeltaCrdt.{CausalCrdt, AddWinsFirstWriteWinsMap, ObservedRemoveMap}

  defmodule State do
    defstruct node_id: nil,
              supervisor_pid: nil,
              members_pid: nil,
              processes_pid: nil,
              members: %{},
              processes: %{},
              processes_updated_counter: 0
  end

  def child_spec(id) do
    %{id: id, start: {__MODULE__, :start_link, [id]}}
  end

  def start_link(children, options) do
    GenServer.start_link(
      __MODULE__,
      {children, Keyword.drop(options, [:name])},
      Keyword.take(options, [:name])
    )
  end

  def stop

  def start_child(supervisor, child_spec), do: call(supervisor, {:start_child, child_spec})

  def terminate_child

  def delete_child

  def restart_child

  def which_children(supervisor), do: call(supervisor, :which_children)

  def count_children(supervisor), do: call(supervisor, :count_children)

  defp call(supervisor, msg), do: GenServer.call(supervisor, msg, @long_time)

  ## GenServer callbacks

  def init({children, options}) do
    node_id = Keyword.get(options, :node_id)
    {:ok, supervisor_pid} = Supervisor.start_link(children, options)

    {:ok, members_pid} = CausalCrdt.start_link(%ObservedRemoveMap{}, {self(), :members_updated})

    {:ok, processes_pid} =
      CausalCrdt.start_link(%ObservedRemoveMap{}, {self(), :processes_updated})

    # add self to members CRDT
    GenServer.call(
      members_pid,
      {:operation,
       {AddWinsFirstWriteWinsMap, :add,
        [node_id, {:alive, supervisor_pid, members_pid, processes_pid}]}}
    )

    state = %State{
      node_id: node_id,
      supervisor_pid: supervisor_pid,
      members_pid: members_pid,
      processes_pid: processes_pid,
      members: %{node_id => {:alive, supervisor_pid, members_pid, processes_pid}}
    }

    add_children(children, state)
    {:ok, state}
  end

  def handle_call({:start_child, child_spec}, _from, state) do
    add_child(child_spec, state)
    {:reply, :ok, state}
  end

  def handle_call(:which_children, _from, state) do
    # delegate to all supervisor pids (probably slow)
  end

  def handle_call(:count_children, _from, state) do
    count =
      state.members
      |> Enum.map(fn {_, {_, s, _, _}} -> s end)
      |> Enum.map(fn supervisor ->
        try do
          Supervisor.count_children(supervisor)
        catch
          :exit, _ -> nil
        end
      end)
      |> Enum.reject(fn
        nil -> true
        _ -> false
      end)
      |> Enum.reduce(%{active: 0, specs: 0, supervisors: 0, workers: 0}, fn a, b ->
        %{
          active: a.active + b.active,
          specs: a.specs + b.specs,
          supervisors: a.supervisors + b.supervisors,
          workers: a.workers + b.workers
        }
      end)

    {:reply, count, state}
  end

  def handle_cast(
        {:request_to_join_horde, {other_node_id, other_members_pid}},
        state
      ) do
    send(state.members_pid, {:add_neighbour, other_members_pid})
    send(state.members_pid, :ship_interval_or_state_to_all)
    {:noreply, state}
  end

  @nodoc
  @doc """
  mark a node as dead if it's supervisor goes down
  """
  def handle_info({:DOWN, _ref, _type, pid, _reason}, state) do
    state.members
    |> Enum.find(fn
      {node_id, {_, ^pid, _, _}} -> true
      _ -> false
    end)
    |> case do
      nil ->
        {:noreply, state}

      {node_id, _node_state} ->
        GenServer.call(
          state.members_pid,
          {:operation, {AddWinsFirstWriteWinsMap, :add, [node_id, {:dead, nil, nil, nil}]}}
        )

        {:noreply, state}
    end
  end

  def handle_info(:processes_updated, state) do
    new_state = %{state | processes_updated_counter: state.processes_updated_counter + 1}
    Process.send_after(self(), {:update_processes, new_state.processes_updated_counter}, 200)
    {:noreply, new_state}
  end

  def handle_info({:update_processes, _c}, %{processes_updated_counter: _c} = state) do
    processes = GenServer.call(state.processes_pid, {:read, AddWinsFirstWriteWinsMap}, 30_000)
    {:noreply, %{state | processes: processes}}
  end

  def handle_info({:update_processes, _counter}, state) do
    {:noreply, state}
  end

  def handle_info(:members_updated, state) do
    members = GenServer.call(state.members_pid, {:read, AddWinsFirstWriteWinsMap}, 30_000)

    new_state = %{state | members: members}

    monitor_supervisors(members)
    handle_updated_members_pids(state, new_state)
    handle_updated_process_pids(state, new_state)
    handle_topology_changes(new_state)

    {:noreply, new_state}
  end

  defp handle_updated_members_pids(state, new_state) do
    new_pids =
      Enum.map(new_state.members, fn {_key, {_, _, m, _}} -> m end) |> Enum.into(MapSet.new())

    old_pids =
      Enum.map(state.members, fn {_node_id, {_, _, m, _}} -> m end) |> Enum.into(MapSet.new())

    # if there are any new pids in `member_pids`
    if MapSet.difference(new_pids, old_pids) |> Enum.any?() do
      send(state.members_pid, {:add_neighbours, new_pids})
      send(state.members_pid, :ship_interval_or_state_to_all)
    end
  end

  defp handle_updated_process_pids(state, new_state) do
    new_pids =
      Enum.map(new_state.members, fn {_key, {_, _, _, p}} -> p end) |> Enum.into(MapSet.new())

    old_pids =
      Enum.map(state.members, fn {_node_id, {_, _, _, p}} -> p end) |> Enum.into(MapSet.new())

    if MapSet.difference(new_pids, old_pids) |> Enum.any?() do
      send(state.processes_pid, {:add_neighbours, new_pids})
      send(state.processes_pid, :ship_interval_or_state_to_all)
    end
  end

  defp dead_members(%{members: members}) do
    Enum.reject(members, fn
      {_, {:alive, _, _, _}} -> true
      _ -> false
    end)
    |> Enum.map(fn {node_id, _} -> node_id end)
  end

  defp handle_topology_changes(state) do
    this_node_id = state.node_id

    dead_members(state)
    |> Enum.map(fn dead_node ->
      state.processes
      |> Enum.filter(fn
        {_id, {^dead_node, _child_spec}} -> true
        _ -> false
      end)
      |> Enum.filter(fn {id, {_node, child}} ->
        chosen = choose_node(child.id, state)

        chosen
        |> case do
          {^this_node_id, _node_info} -> true
          _ -> false
        end
      end)
      |> Enum.map(fn {id, {_node, child}} -> add_child(child, state) end)
    end)
  end

  defp monitor_supervisors(members) do
    Enum.each(members, fn {_, {_, s, _, _}} -> Process.monitor(s) end)
  end

  def handle_cast({:join_horde, other_horde}, state) do
    GenServer.cast(other_horde, {:request_to_join_horde, {state.node_id, state.members_pid}})
    {:noreply, state}
  end

  def handle_call(:members, _from, state) do
    {:reply, {:ok, state.members}, state}
  end

  defp add_children([], _state), do: nil

  defp add_children([child | children], state) do
    add_child(child, state)
    add_children(children, state)
  end

  defp add_child(child, state) do
    {node_id, {_, supervisor_pid, _, _}} = choose_node(child.id, state)

    Supervisor.start_child(supervisor_pid, child)

    GenServer.cast(
      state.processes_pid,
      {:operation, {AddWinsFirstWriteWinsMap, :add, [child.id, {node_id, child}]}}
    )
  end

  defp choose_node(identifier, state) do
    node_ids =
      state.members
      |> Enum.filter(fn
        {_, {:alive, _, _, _}} -> true
        _ -> false
      end)
      |> Enum.sort_by(fn {node_id, _} -> node_id end)

    index = XXHash.xxh32("#{identifier}") |> rem(Enum.count(node_ids))

    Enum.at(node_ids, index)
  end
end
