defmodule Horde.Supervisor do
  @moduledoc """
  A distributed supervisor

  Horde.Supervisor implements a distributed Supervisor backed by a add-wins last-write-wins δ-CRDT (provided by `DeltaCrdt.AWLWWMap`). This CRDT is used for both tracking membership of the cluster and tracking supervised processes.

  Using CRDTs guarantees that the distributed, shared state will eventually converge. It also means that Horde.Supervisor is eventually-consistent, and is optimized for availability and partition tolerance. This can result in temporary inconsistencies under certain conditions (when cluster membership is changing, for example).

  Cluster membership is managed with `Horde.Cluster`. Joining and leaving a cluster can be done with `Horde.Cluster.join_hordes/2` and leaving is done with `Horde.Cluster.leave_hordes/1`.

  Each Horde.Supervisor node wraps its own local instance of `Supervisor`. `Horde.Supervisor.start_child/2` (for example) delegates to the local instance of Supervisor to actually start and monitor the child. The child spec is also written into the processes CRDT, along with a reference to the node on which it is running. When there is an update to the processes CRDT, Horde makes a comparison and corrects any inconsistencies (for example, if a conflict has been resolved and there is a process that no longer should be running on its node, it will kill that process and remove it from the local supervisor). So while most functions map 1:1 to the equivalent Supervisor functions, the eventually consistent nature of Horde requires extra behaviour not present in Supervisor.
  """

  use GenServer

  # 60s
  @long_time 60_000

  # 30 minutes
  @shutdown_wait 30 * 60 * 1000

  @crdt DeltaCrdt.AWLWWMap

  defmodule State do
    @moduledoc false
    defstruct node_id: nil,
              supervisor_pid: nil,
              members_pid: nil,
              processes_pid: nil,
              members: %{},
              processes: %{},
              processes_updated_counter: 0,
              shutting_down: false,
              distribution_strategy: Horde.UniformDistribution
  end

  @doc """
  See `start_link/2` for options.
  """
  def child_spec(options \\ []) do
    options =
      options
      |> Keyword.put_new(:id, __MODULE__)
      |> Keyword.put_new(:children, [])

    %{
      id: options[:id],
      start:
        {__MODULE__, :start_link, [options[:children], Keyword.drop(options, [:id, :children])]}
    }
  end

  @doc """
  Works like `Supervisor.start_link`. Extra options are documented here:
  - `:distribution_strategy`, defaults to `Horde.UniformDistribution` but can also be set to `Horde.UniformQuorumDistribution`. `Horde.UniformQuorumDistribution` enforces a quorum and will shut down all processes on a node if it is split from the rest of the cluster.
  """
  def start_link(children, options) do
    GenServer.start_link(
      __MODULE__,
      {children, Keyword.drop(options, [:name])},
      Keyword.take(options, [:name])
    )
  end

  @doc """
  Works like `Supervisor.stop/3`.
  """
  def stop(supervisor, reason, timeout \\ :infinity),
    do: GenServer.stop(supervisor, reason, timeout)

  @doc """
  Works like `Supervisor.start_child/2`.
  """
  def start_child(supervisor, child_spec),
    do: call(supervisor, {:start_child, Supervisor.child_spec(child_spec, [])})

  @doc """
  Works like `Supervisor.terminate_child/2`
  """
  def terminate_child(supervisor, child_id), do: call(supervisor, {:terminate_child, child_id})

  @doc """
  Works like `Supervisor.delete_child/2`
  """
  def delete_child(supervisor, child_id), do: call(supervisor, {:delete_child, child_id})

  @doc """
  Works like `Supervisor.restart_child/2`
  """
  def restart_child(supervisor, child_id), do: call(supervisor, {:restart_child, child_id})

  @doc """
  Works like `Supervisor.which_children/1`.

  This function delegates to all supervisors in the cluster and returns the aggregated output. Where memory warnings apply to `Supervisor.which_children`, these count double for `Horde.Supervisor.which_children`.
  """
  def which_children(supervisor), do: call(supervisor, :which_children)

  @doc """
  Works like `Supervisor.count_children/1`.

  This function delegates to all supervisors in the cluster and returns the aggregated output.
  """
  def count_children(supervisor), do: call(supervisor, :count_children)

  defp call(supervisor, msg), do: GenServer.call(supervisor, msg, @long_time)

  ## GenServer callbacks

  @doc false
  def init({children, options}) do
    node_id = generate_node_id()
    {:ok, supervisor_pid} = Supervisor.start_link(children, options)

    {:ok, members_pid} = @crdt.start_link({self(), :members_updated})

    {:ok, processes_pid} = @crdt.start_link({self(), :processes_updated})

    # add self to members CRDT
    GenServer.call(
      members_pid,
      {:operation,
       {@crdt, :add, [node_id, {:alive, {self(), supervisor_pid, members_pid, processes_pid}}]}}
    )

    state =
      %State{
        node_id: node_id,
        supervisor_pid: supervisor_pid,
        members_pid: members_pid,
        processes_pid: processes_pid,
        members: %{node_id => {:alive, {self(), supervisor_pid, members_pid, processes_pid}}}
      }
      |> Map.merge(Map.new(Keyword.take(options, [:distribution_strategy])))

    add_children(children, state)
    {:ok, state}
  end

  @doc false
  def terminate(reason, state) do
    Supervisor.stop(state.supervisor_pid, reason)
    GenServer.stop(state.members_pid, reason)
    GenServer.stop(state.processes_pid, reason)
    :ok
  end

  @doc false
  def handle_call(:members, _from, state) do
    {:reply, {:ok, state.members}, state}
  end

  @doc false
  def handle_call({:delete_child, child_id}, _from, state) do
    with {:ok, supervisor_pid} <- which_supervisor(child_id, state),
         :ok <- Supervisor.delete_child(supervisor_pid, child_id) do
      GenServer.cast(
        state.processes_pid,
        {:operation, {@crdt, :remove, [child_id]}}
      )

      {:reply, :ok, state}
    else
      {:error, error} -> {:reply, {:error, error}, state}
    end
  end

  @doc false
  def handle_call({:restart_child, child_id}, _from, state) do
    case which_supervisor(child_id, state) do
      {:ok, supervisor_pid} ->
        {:reply, Supervisor.restart_child(supervisor_pid, child_id), state}

      error ->
        {:reply, error, state}
    end
  end

  @doc false
  def handle_call({:terminate_child, child_id}, _from, state) do
    case which_supervisor(child_id, state) do
      {:ok, supervisor_pid} ->
        {:reply, Supervisor.terminate_child(supervisor_pid, child_id), state}

      error ->
        {:reply, error, state}
    end
  end

  @doc false
  def handle_call({:start_child, _child_spec}, _from, %{shutting_down: true} = state),
    do: {:reply, {:error, "shutting down"}, state}

  @doc false
  def handle_call({:start_child, child_spec}, _from, state) do
    {:reply, add_child(child_spec, state), state}
  end

  @doc false
  def handle_call(:which_children, _from, state) do
    which_children =
      state.members
      |> Enum.map(fn {_, {_, {_, s, _, _}}} -> s end)
      |> Enum.flat_map(fn supervisor_pid ->
        try do
          Supervisor.which_children(supervisor_pid)
        catch
          :exit, _ -> []
        end
      end)

    {:reply, which_children, state}
  end

  @doc false
  def handle_call(:count_children, _from, state) do
    count =
      state.members
      |> Enum.map(fn {_, {_, {_, s, _, _}}} -> s end)
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

  @doc false
  def handle_cast({:join_hordes, other_horde}, state) do
    GenServer.cast(other_horde, {:request_to_join_hordes, {state.node_id, state.members_pid}})
    {:noreply, state}
  end

  @doc false
  def handle_cast(:leave_hordes, state) do
    node_info =
      {:shutting_down, {self(), state.supervisor_pid, state.members_pid, state.processes_pid}}

    GenServer.call(state.members_pid, {:operation, {@crdt, :add, [state.node_id, node_info]}})

    new_members = state.members |> Map.put(state.node_id, node_info)
    new_state = %{state | shutting_down: true, members: new_members}

    handle_this_node_shutting_down(new_state)

    {:noreply, new_state}
  end

  @doc false
  def handle_cast(
        {:request_to_join_hordes, {_other_node_id, other_members_pid}},
        state
      ) do
    send(state.members_pid, {:add_neighbour, other_members_pid})
    send(state.members_pid, :ship_interval_or_state_to_all)
    {:noreply, state}
  end

  defp mark_alive(state) do
    case Map.get(state.members, state.node_id) do
      {:dead, _, _} ->
        member_data =
          {:alive, self(), {state.supervisor_pid, state.members_pid, state.processes_pid}}

        GenServer.call(
          state.members_pid,
          {:operation,
           {@crdt, :add,
            [
              state.node_id,
              member_data
            ]}}
        )

        new_members =
          Map.put(
            state.members,
            state.node_id,
            {:alive, self(), {state.supervisor_pid, state.members_pid, state.processes_pid}}
          )

        %{state | members: new_members}

      _ ->
        state
    end
  end

  defp mark_dead(state, node_id) do
    GenServer.call(
      state.members_pid,
      {:operation, {@crdt, :add, [node_id, {:dead, {nil, nil, nil, nil}}]}}
    )

    state
  end

  @doc false
  def handle_info({:DOWN, _ref, _type, pid, _reason}, state) do
    state.members
    |> Enum.find(fn
      {_node_id, {_, {_, ^pid, _, _}}} -> true
      _ -> false
    end)
    |> case do
      nil -> {:noreply, state}
      {node_id, _node_state} -> {:noreply, mark_dead(state, node_id)}
    end
  end

  @doc false
  def handle_info(:force_shutdown, state) do
    {:stop, :force_shutdown, state}
  end

  @doc false
  def handle_info(:processes_updated, %{shutting_down: true} = state), do: {:noreply, state}

  @doc false
  def handle_info(:processes_updated, state) do
    new_state = %{state | processes_updated_counter: state.processes_updated_counter + 1}
    Process.send_after(self(), {:update_processes, new_state.processes_updated_counter}, 200)
    {:noreply, new_state}
  end

  @doc false
  def handle_info({:update_processes, _c}, %{shutting_down: true} = state), do: {:noreply, state}

  @doc false
  def handle_info({:update_processes, c}, %{processes_updated_counter: c} = state) do
    processes = GenServer.call(state.processes_pid, {:read, @crdt}, 30_000)
    new_state = %{state | processes: processes}
    claim_unclaimed_processes(new_state)
    {:noreply, new_state}
  end

  @doc false
  def handle_info({:update_processes, _counter}, state), do: {:noreply, state}

  @doc false
  def handle_info(:members_updated, %{shutting_down: true} = state), do: {:noreply, state}

  @doc false
  def handle_info(:members_updated, state) do
    members = GenServer.call(state.members_pid, {:read, @crdt}, 30_000)

    new_state = %{state | members: members} |> mark_alive()

    monitor_supervisors(members)
    handle_loss_of_quorum(new_state)
    handle_updated_members_pids(state, new_state)
    handle_updated_process_pids(state, new_state)
    handle_topology_changes(new_state)
    claim_unclaimed_processes(new_state)

    {:noreply, new_state}
  end

  defp handle_loss_of_quorum(state) do
    if !state.distribution_strategy.has_quorum?(state.members) do
      shut_down_all_processes(state)
    end
  end

  defp handle_this_node_shutting_down(state) do
    state.members
    |> Map.get(state.node_id)
    |> case do
      {:alive, _} ->
        nil

      _ ->
        shut_down_all_processes(state)
        Process.send_after(self(), :force_shutdown, @shutdown_wait + 10_000)

        # allow time for state to propagate normally to other nodes
        Process.sleep(10000)

        :ok = Supervisor.stop(state.supervisor_pid)

        send(self(), :force_shutdown)
    end
  end

  defp shut_down_all_processes(state) do
    Task.start_link(fn ->
      this_node = state.node_id

      state.processes
      |> Enum.filter(fn
        {_id, {^this_node, _child_spec}} -> true
        _ -> false
      end)
      |> Enum.map(fn {id, {_this_node, child_spec}} ->
        Task.async(fn ->
          # shut down the child, remove from the supervisor
          :ok = Supervisor.terminate_child(state.supervisor_pid, id)
          :ok = Supervisor.delete_child(state.supervisor_pid, id)

          # mark child as unassigned in the CRDT
          GenServer.cast(
            state.processes_pid,
            {:operation, {@crdt, :add, [child_spec.id, {nil, child_spec}]}}
          )
        end)
      end)
      |> Enum.map(fn task -> Task.await(task, @shutdown_wait) end)
    end)
  end

  defp handle_updated_members_pids(state, new_state) do
    new_pids =
      MapSet.new(new_state.members, fn {_key, {_, {_, _, m, _}}} -> m end)
      |> MapSet.delete(nil)

    old_pids =
      MapSet.new(state.members, fn {_key, {_, {_, _, m, _}}} -> m end)
      |> MapSet.delete(nil)

    # if there are any new pids in `member_pids`
    if MapSet.difference(new_pids, old_pids) |> Enum.any?() do
      send(state.members_pid, {:add_neighbours, new_pids})
      send(state.members_pid, :ship_interval_or_state_to_all)
    end
  end

  defp handle_updated_process_pids(state, new_state) do
    new_pids =
      MapSet.new(new_state.members, fn {_key, {_, {_, _, _, p}}} -> p end)
      |> MapSet.delete(nil)

    old_pids =
      MapSet.new(state.members, fn {_node_id, {_, {_, _, _, p}}} -> p end)
      |> MapSet.delete(nil)

    if MapSet.difference(new_pids, old_pids) |> Enum.any?() do
      send(state.processes_pid, {:add_neighbours, new_pids})
      send(state.processes_pid, :ship_interval_or_state_to_all)
    end
  end

  defp dead_members(%{members: members}) do
    Enum.filter(members, fn
      {_, {:dead, _}} -> true
      _ -> false
    end)
    |> Enum.map(fn {node_id, _} -> node_id end)
  end

  defp processes_for_node(state, node_id) do
    Enum.filter(state.processes, fn
      {_id, {^node_id, _child_spec}} -> true
      _ -> false
    end)
  end

  defp handle_topology_changes(state) do
    this_node_id = state.node_id

    Enum.map(dead_members(state), fn dead_node ->
      processes_for_node(state, dead_node)
      |> Enum.map(fn {_id, {_node, child}} -> child end)
      |> Enum.filter(fn child ->
        case state.distribution_strategy.choose_node(child.id, state.members) do
          {^this_node_id, _node_info} -> true
          _ -> false
        end
      end)
      |> Enum.each(fn child -> add_child(child, state) end)
    end)
  end

  defp claim_unclaimed_processes(state) do
    this_node_id = state.node_id

    state.processes
    |> Enum.each(fn
      {id, {nil, child_spec}} ->
        case state.distribution_strategy.choose_node(id, state.members) do
          {^this_node_id, _node_info} -> add_child(child_spec, state)
          _ -> false
        end

      _ ->
        false
    end)
  end

  defp monitor_supervisors(members) do
    Enum.each(members, fn {_, {_, {_, s, _, _}}} -> Process.monitor(s) end)
  end

  defp which_supervisor(child_id, state) do
    with {node_id, _child_spec} <- Map.get(state.processes, child_id),
         {_node_id, {_h, supervisor_pid, _m, _p}} when not is_nil(supervisor_pid) <-
           Map.get(state.members, node_id) do
      {:ok, supervisor_pid}
    else
      _ -> {:error, :not_found}
    end
  end

  defp add_children([], _state), do: nil

  defp add_children([child | children], state) do
    add_child(child, state)
    add_children(children, state)
  end

  defp add_child(child, state) do
    {node_id, {_, {_, supervisor_pid, _, _}}} =
      state.distribution_strategy.choose_node(child.id, state.members)

    case Supervisor.start_child(supervisor_pid, child) do
      {:ok, pid} ->
        GenServer.cast(
          state.processes_pid,
          {:operation, {@crdt, :add, [child.id, {node_id, child}]}}
        )

        {:ok, pid}

      {:ok, pid, term} ->
        GenServer.cast(
          state.processes_pid,
          {:operation, {@crdt, :add, [child.id, {node_id, child}]}}
        )

        {:ok, pid, term}

      {:error, error} ->
        {:error, error}
    end
  end

  defp generate_node_id(bits \\ 128) do
    <<num::bits>> =
      Enum.reduce(0..Integer.floor_div(bits, 8), <<>>, fn _x, bin ->
        <<Enum.random(0..255)>> <> bin
      end)

    num
  end
end
