defmodule Horde.Supervisor do
  @moduledoc """
  A distributed supervisor.

  Horde.Supervisor implements a distributed DynamicSupervisor backed by a add-wins last-write-wins δ-CRDT (provided by `DeltaCrdt.AWLWWMap`). This CRDT is used for both tracking membership of the cluster and tracking supervised processes.

  Using CRDTs guarantees that the distributed, shared state will eventually converge. It also means that Horde.Supervisor is eventually-consistent, and is optimized for availability and partition tolerance. This can result in temporary inconsistencies under certain conditions (when cluster membership is changing, for example).

  Cluster membership is managed with `Horde.Cluster`. Joining a cluster can be done with `Horde.Cluster.join_hordes/2` and leaving a cluster happens automatically when you stop the supervisor with `Horde.Supervisor.stop/3`.

  Each Horde.Supervisor node wraps its own local instance of `DynamicSupervisor`. `Horde.Supervisor.start_child/2` (for example) delegates to the local instance of DynamicSupervisor to actually start and monitor the child. The child spec is also written into the processes CRDT, along with a reference to the node on which it is running. When there is an update to the processes CRDT, Horde makes a comparison and corrects any inconsistencies (for example, if a conflict has been resolved and there is a process that no longer should be running on its node, it will kill that process and remove it from the local supervisor). So while most functions map 1:1 to the equivalent DynamicSupervisor functions, the eventually consistent nature of Horde requires extra behaviour not present in DynamicSupervisor.

  ## Divergence from standard DynamicSupervisor behaviour

  While Horde wraps DynamicSupervisor, it does keep track of processes by the `id` in the child specification. This is a divergence from the behaviour of DynamicSupervisor, which ignores ids altogether. Using DynamicSupervisor is useful for its shutdown behaviour (it shuts down all child processes simultaneously, unlike `Supervisor`).

  ## Graceful shutdown

  When a node is stopped (either manually or by calling `:init.stop`), Horde restarts the child processes of the stopped node on another node. The state of child processes is not preserved, they are simply restarted.

  To implement graceful shutdown of worker processes, a few extra steps are necessary.

  1. Trap exits. Running `Process.flag(:trap_exit)` in the `init/1` callback of any `worker` processes will convert exit signals to messages and allow running `terminate/2` callbacks. It is also important to include the `shutdown` option in your child spec (the default is 5000ms).

  2. Use `:init.stop()` to shut down your node. How you accomplish this is up to you, but by simply calling `:init.stop()` somewhere, graceful shutdown will be triggered.
  """

  use GenServer

  # 60s
  @long_time 60_000

  @crdt DeltaCrdt.AWLWWMap

  @update_processes_debounce 50
  @force_update_processes 1000

  defmodule State do
    @moduledoc false
    defstruct node_id: nil,
              supervisor_pid: nil,
              members_pid: nil,
              processes_pid: nil,
              options: [],
              members: %{},
              processes: %{},
              processes_updated_counter: 0,
              processes_updated_at: 0,
              shutting_down: false,
              distribution_strategy: Horde.UniformDistribution
  end

  @doc """
  See `start_link/2` for options.
  """
  def child_spec(options \\ []) do
    options = Keyword.put_new(options, :id, __MODULE__)

    %{
      id: options[:id],
      start: {__MODULE__, :start_link, [Keyword.drop(options, [:id])]}
    }
  end

  @doc """
  Works like `DynamicSupervisor.start_link`. Extra options are documented here:
  - `:distribution_strategy`, defaults to `Horde.UniformDistribution` but can also be set to `Horde.UniformQuorumDistribution`. `Horde.UniformQuorumDistribution` enforces a quorum and will shut down all processes on a node if it is split from the rest of the cluster.
  """
  def start_link(options) do
    GenServer.start_link(
      __MODULE__,
      Keyword.drop(options, [:name]),
      Keyword.take(options, [:name])
    )
  end

  @doc """
  Works like `DynamicSupervisor.stop/3`.
  """
  def stop(supervisor, reason \\ :normal, timeout \\ :infinity),
    do: GenServer.stop(supervisor, reason, timeout)

  @doc """
  Works like `DynamicSupervisor.start_child/2`.
  """
  def start_child(supervisor, child_spec) do
    call(supervisor, {:start_child, Supervisor.child_spec(child_spec, [])})
  end

  @doc """
  Works like `DynamicSupervisor.terminate_child/2`
  """
  def terminate_child(supervisor, child_id), do: call(supervisor, {:terminate_child, child_id})

  @doc """
  Works like `DynamicSupervisor.which_children/1`.

  This function delegates to all supervisors in the cluster and returns the aggregated output. Where memory warnings apply to `DynamicSupervisor.which_children`, these count double for `Horde.Supervisor.which_children`.
  """
  def which_children(supervisor), do: call(supervisor, :which_children)

  @doc """
  Works like `DynamicSupervisor.count_children/1`.

  This function delegates to all supervisors in the cluster and returns the aggregated output.
  """
  def count_children(supervisor), do: call(supervisor, :count_children)

  defp call(supervisor, msg), do: GenServer.call(supervisor, msg, @long_time)

  ## GenServer callbacks

  @doc false
  def init(options) do
    Process.flag(:trap_exit, true)

    node_id = generate_node_id()

    {:ok, supervisor_pid} = DynamicSupervisor.start_link(options)

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
        options: options,
        members: %{node_id => {:alive, {self(), supervisor_pid, members_pid, processes_pid}}}
      }
      |> Map.merge(Map.new(Keyword.take(options, [:distribution_strategy])))

    {:ok, state}
  end

  @doc false
  def terminate(reason, state) do
    node_info =
      {:shutting_down, {self(), state.supervisor_pid, state.members_pid, state.processes_pid}}

    GenServer.cast(state.members_pid, {:operation, {@crdt, :add, [state.node_id, node_info]}})

    GenServer.stop(state.supervisor_pid, reason)

    GenServer.stop(state.members_pid, reason, 2000)

    GenServer.stop(state.processes_pid, reason, 2000)

    :ok
  end

  @doc false
  def handle_call(:members, _from, state) do
    {:reply, {:ok, state.members}, state}
  end

  @doc false
  def handle_call({:terminate_child, child_id} = msg, from, %{node_id: this_node_id} = state) do
    case Map.get(state.processes, child_id) do
      {^this_node_id, _child_spec} ->
        reply =
          DynamicSupervisor.terminate_child(
            state.supervisor_pid,
            Process.whereis(Horde.ProcessSupervisor.name(this_node_id, child_id))
          )

        new_state = %{state | processes: Map.delete(state.processes, child_id)}
        :ok = GenServer.cast(state.processes_pid, {:operation, {@crdt, :remove, [child_id]}})
        {:reply, reply, new_state}

      {other_node, _child_spec} ->
        proxy_to_node(other_node, msg, from, state)
    end
  end

  @doc false
  def handle_call({:start_child, _child_spec}, _from, %{shutting_down: true} = state),
    do: {:reply, {:error, {:shutting_down, "this node is shutting down."}}, state}

  @doc false
  def handle_call({:start_child, child_spec} = msg, from, %{node_id: this_node_id} = state) do
    case state.distribution_strategy.choose_node(child_spec.id, state.members) do
      {^this_node_id, _} ->
        {reply, new_state} = add_child(child_spec, state)
        {:reply, reply, new_state}

      {other_node_id, _} ->
        proxy_to_node(other_node_id, msg, from, state)
    end
  end

  @doc false
  def handle_call(:which_children, _from, state) do
    which_children =
      state.members
      |> Enum.map(fn {_, {_, {_, s, _, _}}} -> s end)
      |> Enum.flat_map(fn supervisor_pid ->
        try do
          DynamicSupervisor.which_children(supervisor_pid)
          |> Enum.map(fn
            {:undefined, :restarting, _, _} = child -> child
            {:undefined, pid, _, _} -> Supervisor.which_children(pid)
          end)
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
      |> Enum.flat_map(fn supervisor_pid ->
        try do
          DynamicSupervisor.which_children(supervisor_pid)
          |> Enum.map(fn
            {:undefined, :restarting, _, _} ->
              %{restarting: 1}

            {:undefined, pid, _, _} ->
              count = Supervisor.count_children(pid)
              %{count | workers: count.workers - 1}
          end)
        catch
          :exit, _ -> [nil]
        end
      end)
      |> Enum.reject(fn
        nil -> true
        _ -> false
      end)
      |> Enum.reduce(%{}, fn a, b ->
        Map.merge(a, b, fn _key, v1, v2 -> v1 + v2 end)
      end)

    {:reply, count, state}
  end

  @doc false
  def handle_call({:join_hordes, other_horde}, from, state) do
    GenServer.cast(
      other_horde,
      {:request_to_join_hordes, {state.node_id, state.members_pid, from}}
    )

    {:noreply, state}
  end

  @doc false
  def handle_cast(
        {:request_to_join_hordes, {_other_node_id, other_members_pid, reply_to}},
        state
      ) do
    send(state.members_pid, {:add_neighbour, other_members_pid})
    send(state.members_pid, :ship_interval_or_state_to_all)
    GenServer.reply(reply_to, true)
    {:noreply, state}
  end

  defp proxy_to_node(node_id, message, reply_to, state) do
    case Map.get(state.members, node_id) do
      {:alive, {other_node_pid, _, _, _}} ->
        send(other_node_pid, {:proxy_operation, message, reply_to})
        {:noreply, state}

      _ ->
        {:reply,
         {:error,
          {:node_dead_or_shutting_down,
           "the node responsible for this process is shutting down or dead, try again soon"}},
         state}
    end
  end

  defp mark_alive(state) do
    case Map.get(state.members, state.node_id) do
      {:dead, _, _} ->
        member_data =
          {:alive, {self(), state.supervisor_pid, state.members_pid, state.processes_pid}}

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
            {:alive, {self(), state.supervisor_pid, state.members_pid, state.processes_pid}}
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

  def handle_info({:proxy_operation, msg, reply_to}, state) do
    case handle_call(msg, reply_to, state) do
      {:reply, reply, new_state} ->
        GenServer.reply(reply_to, reply)
        {:noreply, new_state}

      {:noreply, new_state} ->
        {:noreply, new_state}
    end
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

    Process.send_after(
      self(),
      {:update_processes, new_state.processes_updated_counter},
      @update_processes_debounce
    )

    {:noreply, new_state}
  end

  @doc false
  def handle_info({:update_processes, _c}, %{shutting_down: true} = state), do: {:noreply, state}

  def handle_info(
        {:update_processes, c},
        %{processes_updated_at: d, processes_updated_counter: new_c} = state
      )
      when d - c > @force_update_processes do
    handle_info({:update_processes, new_c}, state)
  end

  @doc false
  def handle_info({:update_processes, c}, %{processes_updated_counter: c} = state) do
    processes = GenServer.call(state.processes_pid, {:read, @crdt}, 30_000)

    new_state =
      %{state | processes: processes, processes_updated_at: c}
      |> stop_not_owned_processes(state)
      |> claim_unclaimed_processes()

    {:noreply, new_state}
  end

  @doc false
  def handle_info({:update_processes, _counter}, state), do: {:noreply, state}

  @doc false
  def handle_info(:members_updated, %{shutting_down: true} = state), do: {:noreply, state}

  @doc false
  def handle_info(:members_updated, state) do
    members = GenServer.call(state.members_pid, {:read, @crdt}, 30_000)

    monitor_supervisors(members)

    new_state =
      %{state | members: members}
      |> mark_alive()
      |> handle_loss_of_quorum()
      |> handle_updated_members_pids(state)
      |> handle_updated_process_pids(state)
      |> handle_topology_changes()
      |> claim_unclaimed_processes()

    {:noreply, new_state}
  end

  defp stop_not_owned_processes(new_state, old_state) do
    old_process_ids =
      processes_for_node(old_state, old_state.node_id) |> MapSet.new(fn {id, _rest} -> id end)

    new_process_ids =
      processes_for_node(new_state, new_state.node_id) |> MapSet.new(fn {id, _rest} -> id end)

    MapSet.difference(old_process_ids, new_process_ids)
    |> Enum.map(fn id ->
      :ok =
        DynamicSupervisor.terminate_child(
          new_state.supervisor_pid,
          Process.whereis(Horde.ProcessSupervisor.name(new_state.node_id, id))
        )
    end)

    new_state
  end

  defp handle_loss_of_quorum(state) do
    if !state.distribution_strategy.has_quorum?(state.members) do
      shut_down_all_processes(state)
    else
      state
    end
  end

  defp shut_down_all_processes(state) do
    :ok = GenServer.stop(state.supervisor_piod, :normal, :infinity)
    {:ok, supervisor_pid} = DynamicSupervisor.start_link(state.options)
    %{state | supervisor_pid: supervisor_pid}
  end

  defp handle_updated_members_pids(new_state, state) do
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

    new_state
  end

  defp handle_updated_process_pids(new_state, state) do
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

    new_state
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

    Enum.flat_map(dead_members(state), fn dead_node ->
      processes_for_node(state, dead_node)
      |> Enum.map(fn {_id, {_node, child}} -> child end)
      |> Enum.filter(fn child ->
        case state.distribution_strategy.choose_node(child.id, state.members) do
          {^this_node_id, _node_info} -> true
          _ -> false
        end
      end)
    end)
    |> Enum.reduce(state, fn child, state ->
      {_ret, state} = add_child(child, state)
      state
    end)
  end

  defp claim_unclaimed_processes(state) do
    this_node_id = state.node_id

    state.processes
    |> Enum.flat_map(fn
      {id, {nil, child_spec}} ->
        case state.distribution_strategy.choose_node(id, state.members) do
          {^this_node_id, _node_info} -> [child_spec]
          _ -> []
        end

      _ ->
        []
    end)
    |> Enum.reduce(state, fn child_spec, state ->
      {_ret, state} = add_child(child_spec, state)
      state
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

  defp add_child(child, state) do
    {node_id, {_, {_, supervisor_pid, _, _}}} =
      state.distribution_strategy.choose_node(child.id, state.members)

    wrapped_child = {Horde.ProcessSupervisor, {child, state.processes_pid, state.node_id}}

    case DynamicSupervisor.start_child(supervisor_pid, wrapped_child) do
      {:ok, process_supervisor_pid} ->
        case Supervisor.start_child(process_supervisor_pid, child) do
          {:ok, child_pid} ->
            GenServer.cast(
              state.processes_pid,
              {:operation, {@crdt, :add, [child.id, {node_id, child}]}}
            )

            new_state = %{state | processes: Map.put(state.processes, child.id, {node_id, child})}

            {{:ok, child_pid}, new_state}

          {:ok, child_pid, term} ->
            GenServer.cast(
              state.processes_pid,
              {:operation, {@crdt, :add, [child.id, {node_id, child}]}}
            )

            new_state = %{state | processes: Map.put(state.processes, child.id, {node_id, child})}

            {{:ok, child_pid, term}, new_state}

          {:error, error} ->
            DynamicSupervisor.terminate_child(supervisor_pid, process_supervisor_pid)
            {{:error, error}, state}
        end

      {:error, error} ->
        {{:error, error}, state}
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
