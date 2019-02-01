defmodule Horde.Supervisor.Member do
  @type t :: %Horde.Supervisor.Member{}
  defstruct [:node_id, :status, :pid, :name, :members_pid, :processes_pid]
end

defmodule Horde.SupervisorImpl do
  @moduledoc false

  require Logger
  use GenServer

  defstruct pid: nil,
            node_id: nil,
            name: nil,
            members_pid: nil,
            processes_pid: nil,
            members: %{},
            processes: %{},
            processes_updated_counter: 0,
            processes_updated_at: 0,
            shutting_down: false,
            supervisor_options: [],
            distribution_strategy: Horde.UniformDistribution

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  ## GenServer callbacks
  defp members_name(name), do: :"#{name}.MembersCrdt"
  defp processes_name(name), do: :"#{name}.ProcessesCrdt"
  defp processes_supervisor_name(name), do: :"#{name}.ProcessesSupervisor"
  defp registry_name(name), do: :"#{name}.Registry"

  @doc false
  def init(options) do
    name = Keyword.get(options, :name)

    Logger.info("Starting #{inspect(__MODULE__)} with name #{inspect(name)}")

    Process.flag(:trap_exit, true)

    state =
      %__MODULE__{
        pid: self(),
        node_id: generate_node_id(),
        supervisor_options: options,
        name: name,
        members_pid: Process.whereis(members_name(name)),
        processes_pid: Process.whereis(processes_name(name))
      }
      |> Map.merge(Map.new(Keyword.take(options, [:distribution_strategy])))

    state = %{state | members: %{state.node_id => node_info(state)}}

    # add self to members CRDT
    DeltaCrdt.mutate(members_name(name), :add, [state.node_id, node_info(state)], :infinity)

    Registry.start_link(keys: :unique, name: registry_name(name))

    {:ok, state}
  end

  defp node_info(state) do
    %Horde.Supervisor.Member{status: node_status(state)}
    |> Map.merge(Map.take(state, [:node_id, :pid, :name, :members_pid, :processes_pid]))
  end

  defp node_status(%{shutting_down: false}), do: :alive
  defp node_status(%{shutting_down: true}), do: :shutting_down

  @doc false
  def handle_call(:horde_shutting_down, _f, state) do
    state = %{state | shutting_down: true}

    DeltaCrdt.mutate(members_name(state.name), :add, [state.node_id, node_info(state)], :infinity)

    {:reply, :ok, state}
  end

  def handle_call(:members, _from, state) do
    {:reply, {:ok, state.members}, state}
  end

  def handle_call({:terminate_child, child_id} = msg, from, %{node_id: this_node_id} = state) do
    case Map.get(state.processes, child_id) do
      {^this_node_id, _child_spec} ->
        reply =
          Horde.DynamicSupervisor.terminate_child_by_id(
            processes_supervisor_name(state.name),
            child_id
          )

        new_state = %{state | processes: Map.delete(state.processes, child_id)}

        :ok = DeltaCrdt.mutate(processes_name(state.name), :remove, [child_id], :infinity)

        {:reply, reply, new_state}

      {other_node, _child_spec} ->
        proxy_to_node(other_node, msg, from, state)

      nil ->
        case state.distribution_strategy.choose_node(child_id, Map.values(state.members)) do
          {:ok, %{node_id: ^this_node_id}} ->
            {:reply, {:error, :not_found}, state}

          {:ok, %{node_id: other_node_id}} ->
            proxy_to_node(other_node_id, msg, from, state)

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:start_child, _child_spec}, _from, %{shutting_down: true} = state),
    do: {:reply, {:error, {:shutting_down, "this node is shutting down."}}, state}

  def handle_call({:start_child, child_spec} = msg, from, %{node_id: this_node_id} = state) do
    case state.distribution_strategy.choose_node(child_spec.id, Map.values(state.members)) do
      {:ok, %{node_id: ^this_node_id}} ->
        {reply, new_state} = add_child(child_spec, state)
        {:reply, reply, new_state}

      {:ok, %{node_id: other_node_id}} ->
        proxy_to_node(other_node_id, msg, from, state)

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:which_children, _from, state) do
    which_children =
      Enum.flat_map(state.members, fn
        {_, %{pid: pid, name: name}} ->
          [{processes_supervisor_name(name), node(pid)}]
      end)
      |> Enum.flat_map(fn supervisor_pid ->
        try do
          Horde.DynamicSupervisor.which_children(supervisor_pid)
        catch
          :exit, _ -> []
        end
      end)

    {:reply, which_children, state}
  end

  def handle_call(:count_children, _from, state) do
    count =
      Enum.flat_map(state.members, fn
        {_, %{pid: pid, name: name}} ->
          [{processes_supervisor_name(name), node(pid)}]
      end)
      |> Enum.flat_map(fn supervisor_pid ->
        try do
          Horde.DynamicSupervisor.count_children(supervisor_pid)
        catch
          :exit, _ -> [nil]
        end
      end)
      |> Enum.reject(fn
        nil -> true
        _ -> false
      end)
      |> Enum.reduce(%{}, fn {process_type, count}, acc ->
        Map.update(acc, process_type, count, &(&1 + count))
      end)

    {:reply, count, state}
  end

  def handle_call({:join_hordes, other_horde}, from, state) do
    GenServer.cast(
      other_horde,
      {:request_to_join_hordes,
       {:supervisor, state.node_id, Process.whereis(members_name(state.name)), from}}
    )

    {:noreply, state}
  end

  @doc false
  def handle_cast(
        {:request_to_join_hordes, {:supervisor, _other_node_id, other_members_pid, reply_to}},
        state
      ) do
    send(members_name(state.name), {:add_neighbours, [other_members_pid]})

    GenServer.reply(reply_to, :ok)
    {:noreply, mark_alive(state, true)}
  end

  def handle_cast({:disown_child_process, child_id}, state) do
    new_state = %{state | processes: Map.delete(state.processes, child_id)}
    :ok = DeltaCrdt.mutate(processes_name(state.name), :remove, [child_id], :infinity)
    {:noreply, new_state}
  end

  defp proxy_to_node(node_id, message, reply_to, state) do
    case Map.get(state.members, node_id) do
      %{status: :alive, pid: other_node_pid} ->
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

  defp mark_alive(state, force \\ false) do
    if !force && Map.has_key?(state.members, state.node_id) do
      state
    else
      DeltaCrdt.mutate(
        members_name(state.name),
        :add,
        [state.node_id, node_info(state)],
        :infinity
      )

      new_members = Map.put(state.members, state.node_id, node_info(state))
      Map.put(state, :members, new_members)
    end
  end

  defp mark_dead(state, node_id) do
    DeltaCrdt.mutate(members_name(state.name), :remove, [node_id], :infinity)
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
      {_node_id, %{pid: ^pid}} -> true
      _ -> false
    end)
    |> case do
      nil ->
        {:noreply, state}

      {node_id, _node_state} ->
        new_state =
          mark_dead(state, node_id)
          |> mark_alive()

        {:noreply, new_state}
    end
  end

  @doc false
  def handle_info({:processes_updated, reply_to}, %{shutting_down: true} = state) do
    GenServer.reply(reply_to, :ok)
    {:noreply, state}
  end

  @doc false
  def handle_info({:processes_updated, reply_to}, state) do
    processes = DeltaCrdt.read(processes_name(state.name), 30_000)

    new_state =
      %{state | processes: processes}
      |> handle_topology_changes()
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
    members = DeltaCrdt.read(members_name(state.name), 30_000)

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
      Horde.DynamicSupervisor.terminate_child_by_id(
        processes_supervisor_name(new_state.name),
        id
      )

      :ok
    end)

    new_state
  end

  defp handle_loss_of_quorum(state) do
    if !state.distribution_strategy.has_quorum?(Map.values(state.members)) do
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
        {_key, %{status: :alive, members_pid: members_pid}} ->
          members_pid

        _ ->
          nil
      end)
      |> MapSet.delete(nil)

    old_members =
      MapSet.new(state.members, fn
        {_key, %{status: :alive, members_pid: members_pid}} ->
          members_pid

        _ ->
          nil
      end)
      |> MapSet.delete(nil)

    # if there are new pids in `member_pids`
    if !Enum.empty?(MapSet.difference(new_members, old_members)) do
      send(state.members_pid, {:add_neighbours, new_members})
    end

    new_state
  end

  defp handle_updated_process_pids(new_state, state) do
    new_processes =
      MapSet.new(new_state.members, fn
        {_key, %{status: :alive, processes_pid: processes_pid}} ->
          processes_pid

        _ ->
          nil
      end)
      |> MapSet.delete(nil)

    old_processes =
      MapSet.new(state.members, fn
        {_key, %{status: :alive, processes_pid: processes_pid}} ->
          processes_pid

        _ ->
          nil
      end)
      |> MapSet.delete(nil)

    if !Enum.empty?(MapSet.difference(new_processes, old_processes)) do
      send(state.processes_pid, {:add_neighbours, new_processes})
    end

    new_state
  end

  defp processes_for_node(state, node_id) do
    Enum.filter(state.processes, fn
      {_id, {^node_id, _child_spec}} -> true
      _ -> false
    end)
  end

  defp handle_topology_changes(state) do
    this_node_id = state.node_id

    {_responses, new_state} =
      processes_on_dead_nodes(state)
      |> Enum.map(fn {_id, {_node, child}} -> child end)
      |> Enum.filter(fn child ->
        case state.distribution_strategy.choose_node(child.id, Map.values(state.members)) do
          {:ok, %{node_id: ^this_node_id}} -> true
          _ -> false
        end
      end)
      |> add_children(state)

    new_state
  end

  def processes_on_dead_nodes(%{processes: processes, members: members}) do
    member_ids = Map.keys(members) |> MapSet.new()

    procs =
      Enum.filter(processes, fn
        {_id, {node_id, _child_spec}} ->
          !MapSet.member?(member_ids, node_id)
      end)

    if !Enum.empty?(procs) do
      Logger.debug(fn ->
        "Found #{Enum.count(procs)} processes on dead nodes"
      end)
    end

    procs
  end

  defp claim_unclaimed_processes(%{node_id: this_node_id} = state) do
    {_responses, new_state} =
      Enum.flat_map(state.processes, fn
        {id, {nil, child_spec}} ->
          case state.distribution_strategy.choose_node(id, Map.values(state.members)) do
            {:ok, %{node_id: ^this_node_id}} -> [child_spec]
            _ -> []
          end

        _ ->
          []
      end)
      |> add_children(state)

    new_state
  end

  defp monitor_supervisors(members, state) do
    Enum.each(members, fn {node_id, %{pid: pid}} ->
      if(!Map.get(state.members, node_id)) do
        Process.monitor(pid)
      end
    end)
  end

  defp update_state_with_child(child, state) do
    :ok =
      DeltaCrdt.mutate(
        processes_name(state.name),
        :add,
        [child.id, {state.node_id, child}],
        :infinity
      )

    %{state | processes: Map.put(state.processes, child.id, {state.node_id, child})}
  end

  defp add_child(child, state) do
    {[response], new_state} = add_children([child], state)
    {response, new_state}
  end

  defp add_children(children, state) do
    Enum.map(children, fn child ->
      case Horde.DynamicSupervisor.start_child(processes_supervisor_name(state.name), child) do
        {:ok, process_pid} ->
          {{:ok, process_pid}, child}

        {:error, error} ->
          {:error, error}
      end
    end)
    |> Enum.reduce({[], state}, fn
      {:error, error}, {responses, state} ->
        {[{:error, error} | responses], state}

      {{:ok, _child_pid, _term} = resp, child}, {responses, state} ->
        {[resp | responses], update_state_with_child(child, state)}

      {{:ok, _child_pid} = resp, child}, {responses, state} ->
        {[resp | responses], update_state_with_child(child, state)}
    end)
  end

  defp generate_node_id(bytes \\ 16) do
    :base64.encode(:crypto.strong_rand_bytes(bytes))
  end
end
