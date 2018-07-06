defmodule Horde.SupervisorImpl do
  require Logger
  use GenServer
  # 60s

  defmodule State do
    @moduledoc false
    defstruct node_id: nil,
              name: nil,
              members: %{},
              processes: %{},
              processes_updated_counter: 0,
              processes_updated_at: 0,
              shutting_down: false,
              distribution_strategy: Horde.UniformDistribution
  end

  def start_link(opts) do
    name = Keyword.get(opts, :name, nil)

    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  ## GenServer callbacks
  defp members_name(name), do: :"#{name}.MembersCrdt"
  defp processes_name(name), do: :"#{name}.ProcessesCrdt"
  defp processes_supervisor_name(name), do: :"#{name}.ProcessesSupervisor"
  defp graceful_shutdown_manager_name(name), do: :"#{name}.GracefulShutdownManager"

  @doc false
  def init(options) do
    name = Keyword.get(options, :name)

    Process.flag(:trap_exit, true)

    node_id = generate_node_id()

    # add self to members CRDT
    GenServer.call(
      members_name(name),
      {:operation, {:add, [node_id, {:alive, self(), name}]}},
      :infinity
    )

    state =
      %State{
        node_id: node_id,
        name: name,
        members: %{node_id => {:alive, self(), name}}
      }
      |> Map.merge(Map.new(Keyword.take(options, [:distribution_strategy])))

    {:ok, state}
  end

  @doc false
  def handle_call(:horde_shutting_down, _f, state) do
    GenServer.call(
      members_name(state.name),
      {:operation, {:add, [state.node_id, {:shutting_down, self(), state.name}]}},
      :infinity
    )

    {:reply, :ok, %{state | shutting_down: true}}
  end

  def handle_call(:members, _from, state) do
    {:reply, {:ok, state.members}, state}
  end

  def handle_call({:terminate_child, child_id} = msg, from, %{node_id: this_node_id} = state) do
    case Map.get(state.processes, child_id) do
      {^this_node_id, _child_spec} ->
        reply =
          DynamicSupervisor.terminate_child(
            processes_supervisor_name(state.name),
            Process.whereis(Horde.ProcessSupervisor.name(this_node_id, child_id))
          )

        new_state = %{state | processes: Map.delete(state.processes, child_id)}

        :ok =
          GenServer.call(
            processes_name(state.name),
            {:operation, {:remove, [child_id]}},
            :infinity
          )

        {:reply, reply, new_state}

      {other_node, _child_spec} ->
        proxy_to_node(other_node, msg, from, state)
    end
  end

  def handle_call({:start_child, _child_spec}, _from, %{shutting_down: true} = state),
    do: {:reply, {:error, {:shutting_down, "this node is shutting down."}}, state}

  def handle_call({:start_child, child_spec} = msg, from, %{node_id: this_node_id} = state) do
    case state.distribution_strategy.choose_node(child_spec.id, state.members) do
      {^this_node_id, _} ->
        {reply, new_state} = add_child(child_spec, state)
        {:reply, reply, new_state}

      {other_node_id, _} ->
        proxy_to_node(other_node_id, msg, from, state)
    end
  end

  def handle_call(:which_children, _from, state) do
    which_children =
      Enum.flat_map(state.members, fn
        {_node_id, {_status, nil, nil}} ->
          []

        {_, {_, pid, name}} ->
          [{processes_supervisor_name(name), node(pid)}]
      end)
      |> Enum.flat_map(fn supervisor_pid ->
        try do
          DynamicSupervisor.which_children(supervisor_pid)
          |> Enum.map(fn
            {:undefined, :restarting, _, _} = child ->
              child

            {:undefined, pid, _, _} ->
              Enum.filter(Supervisor.which_children(pid), fn
                {Horde.ProcessCanary, _, _, _} -> false
                _ -> true
              end)
          end)
        catch
          :exit, _ -> []
        end
      end)

    {:reply, which_children, state}
  end

  def handle_call(:count_children, _from, state) do
    count =
      Enum.flat_map(state.members, fn
        {_node_id, {_status, nil, nil}} ->
          []

        {_, {_, pid, name}} ->
          [{processes_supervisor_name(name), node(pid)}]
      end)
      |> Enum.flat_map(fn supervisor_pid ->
        try do
          DynamicSupervisor.which_children(supervisor_pid)
          |> Enum.map(fn
            {:undefined, :restarting, _, _} ->
              %{restarting: 1}

            {:undefined, pid, _, _} ->
              count = Supervisor.count_children(pid)

              %{
                count
                | workers: count.workers - 1,
                  active: count.active - 1,
                  specs: count.specs - 1
              }
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

  def handle_call({:join_hordes, other_horde}, from, state) do
    GenServer.cast(
      other_horde,
      {:request_to_join_hordes, {state.node_id, {members_name(state.name), Node.self()}, from}}
    )

    {:noreply, state}
  end

  @doc false
  def handle_cast(
        {:request_to_join_hordes, {_other_node_id, other_members_pid, reply_to}},
        state
      ) do
    send(members_name(state.name), {:add_neighbour, other_members_pid})
    GenServer.reply(reply_to, true)
    {:noreply, state}
  end

  defp proxy_to_node(node_id, message, reply_to, state) do
    case Map.get(state.members, node_id) do
      {:alive, other_node_pid, _other_node_name} ->
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
        member_data = {:alive, self(), state.name}

        GenServer.call(
          members_name(state.name),
          {:operation,
           {:add,
            [
              state.node_id,
              member_data
            ]}},
          :infinity
        )

        new_members = Map.put(state.members, state.node_id, {:alive, self(), state.name})

        %{state | members: new_members}

      _ ->
        state
    end
  end

  defp mark_dead(state, node_id) do
    GenServer.call(
      members_name(state.name),
      {:operation, {:add, [node_id, {:dead, nil, nil}]}},
      :infinity
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
    Enum.find(state.members, fn
      {_node_id, {_status, ^pid, _name}} -> true
      _ -> false
    end)
    |> case do
      nil -> {:noreply, state}
      {node_id, _node_state} -> {:noreply, mark_dead(state, node_id)}
    end
  end

  @doc false
  def handle_info({:processes_updated, reply_to}, %{shutting_down: true} = state) do
    GenServer.reply(reply_to, :ok)
    {:noreply, state}
  end

  @doc false
  def handle_info({:processes_updated, reply_to}, state) do
    processes = DeltaCrdt.CausalCrdt.read(processes_name(state.name), 30_000)

    new_state =
      %{state | processes: processes}
      |> stop_not_owned_processes(state)
      |> claim_unclaimed_processes()

    GenServer.reply(reply_to, :ok)

    {:noreply, new_state}
  end

  @doc false
  def handle_info({:members_updated, reply_to}, %{shutting_down: true} = state) do
    GenServer.reply(reply_to, :ok)
    {:noreply, state}
  end

  @doc false
  def handle_info({:members_updated, reply_to}, state) do
    members = DeltaCrdt.CausalCrdt.read(members_name(state.name), 30_000)

    monitor_supervisors(members, state)

    new_state =
      %{state | members: members}
      |> mark_alive()
      |> handle_loss_of_quorum()
      |> handle_updated_members_pids(state)
      |> handle_updated_process_pids(state)
      |> handle_topology_changes()
      |> claim_unclaimed_processes()

    GenServer.reply(reply_to, :ok)

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
          processes_supervisor_name(new_state.name),
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
    :ok = GenServer.stop(processes_supervisor_name(state.name), :normal, :infinity)
    state
  end

  defp handle_updated_members_pids(new_state, state) do
    new_members =
      MapSet.new(new_state.members, fn
        {_key, {:alive, pid, name}} ->
          {members_name(name), node(pid)}

        _ ->
          nil
      end)
      |> MapSet.delete(nil)

    old_members =
      MapSet.new(state.members, fn
        {_key, {:alive, pid, name}} ->
          {members_name(name), node(pid)}

        _ ->
          nil
      end)
      |> MapSet.delete(nil)

    # if there are any new pids in `member_pids`
    if MapSet.difference(new_members, old_members) |> Enum.any?() do
      send(members_name(state.name), {:add_neighbours, new_members})
    end

    new_state
  end

  defp handle_updated_process_pids(new_state, state) do
    new_processes =
      MapSet.new(new_state.members, fn
        {_key, {:alive, pid, name}} ->
          {processes_name(name), node(pid)}

        _ ->
          nil
      end)
      |> MapSet.delete(nil)

    old_processes =
      MapSet.new(state.members, fn
        {_key, {:alive, pid, name}} ->
          {processes_name(name), node(pid)}

        _ ->
          nil
      end)
      |> MapSet.delete(nil)

    if MapSet.difference(new_processes, old_processes) |> Enum.any?() do
      send(processes_name(state.name), {:add_neighbours, new_processes})
    end

    new_state
  end

  defp dead_members(%{members: members}) do
    Enum.filter(members, fn
      {_, {:dead, _, _}} -> true
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

  defp claim_unclaimed_processes(%{node_id: this_node_id} = state) do
    Enum.flat_map(state.processes, fn
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

  defp monitor_supervisors(members, state) do
    Enum.each(members, fn {node_id, {_state, pid, _name}} ->
      if(!Map.get(state.members, node_id)) do
        Process.monitor(pid)
      end
    end)
  end

  defp update_state_with_child(child, state) do
    GenServer.call(
      processes_name(state.name),
      {:operation, {:add, [child.id, {state.node_id, child}]}},
      :infinity
    )

    %{state | processes: Map.put(state.processes, child.id, {state.node_id, child})}
  end

  defp add_child(child, state) do
    wrapped_child =
      {Horde.ProcessSupervisor,
       {child, graceful_shutdown_manager_name(state.name), state.node_id}}

    case DynamicSupervisor.start_child(processes_supervisor_name(state.name), wrapped_child) do
      {:ok, process_supervisor_pid} ->
        case Supervisor.start_child(process_supervisor_pid, child) do
          {:ok, child_pid} ->
            {{:ok, child_pid}, update_state_with_child(child, state)}

          {:ok, child_pid, term} ->
            {{:ok, child_pid, term}, update_state_with_child(child, state)}

          {:error, error} ->
            DynamicSupervisor.terminate_child(
              processes_supervisor_name(state.name),
              process_supervisor_pid
            )

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
