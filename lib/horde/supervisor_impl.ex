defmodule Horde.Supervisor.Member do
  @moduledoc false

  @type t :: %Horde.Supervisor.Member{}
  @type status :: :uninitialized | :alive | :shutting_down | :dead
  defstruct [:status, :name]
end

defmodule Horde.SupervisorImpl do
  @moduledoc false

  require Logger
  use GenServer

  defstruct name: nil,
            members: %{},
            processes: %{},
            waiting_for_quorum: [],
            processes_updated_counter: 0,
            processes_updated_at: 0,
            supervisor_ref_to_name: %{},
            name_to_supervisor_ref: %{},
            shutting_down: false,
            supervisor_options: [],
            distribution_strategy: Horde.UniformDistribution

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  ## GenServer callbacks
  defp members_crdt_name(name), do: :"#{name}.MembersCrdt"
  defp members_status_crdt_name(name), do: :"#{name}.MemberStatusCrdt"
  defp processes_crdt_name(name), do: :"#{name}.ProcessesCrdt"
  defp supervisor_name(name), do: :"#{name}.ProcessesSupervisor"

  defp fully_qualified_name({name, node}) when is_atom(name) and is_atom(node), do: {name, node}
  defp fully_qualified_name(name) when is_atom(name), do: {name, node()}

  @doc false
  def init(options) do
    {:ok, options} =
      case Keyword.get(options, :init_module) do
        nil -> {:ok, options}
        module -> module.init(options)
      end

    name = Keyword.get(options, :name)

    Logger.info("Starting #{inspect(__MODULE__)} with name #{inspect(name)}")

    Process.flag(:trap_exit, true)

    state =
      %__MODULE__{
        supervisor_options: options,
        name: name
      }
      |> Map.merge(Map.new(Keyword.take(options, [:distribution_strategy])))

    state = set_own_node_status(state)

    {:ok, state, {:continue, {:set_members, Keyword.get(options, :members)}}}
  end

  def handle_continue({:set_members, nil}, state), do: {:noreply, state}

  def handle_continue({:set_members, members}, state) do
    {:noreply, set_members(members, state)}
  end

  defp node_info(state) do
    %Horde.Supervisor.Member{status: node_status(state), name: fully_qualified_name(state.name)}
  end

  defp node_status(%{shutting_down: false}), do: :alive
  defp node_status(%{shutting_down: true}), do: :shutting_down

  @doc false
  def handle_call(:horde_shutting_down, _f, state) do
    state = %{state | shutting_down: true}

    DeltaCrdt.mutate(
      members_status_crdt_name(state.name),
      :add,
      [fully_qualified_name(state.name), node_info(state)],
      :infinity
    )

    {:reply, :ok, state}
  end

  def handle_call(:wait_for_quorum, from, state) do
    if state.distribution_strategy.has_quorum?(Map.values(state.members)) do
      {:reply, :ok, state}
    else
      {:noreply, %{state | waiting_for_quorum: [from | state.waiting_for_quorum]}}
    end
  end

  def handle_call({:set_members, members}, _from, state) do
    {:reply, :ok, set_members(members, state)}
  end

  def handle_call(:members, _from, state) do
    {:reply, {:ok, Map.keys(state.members)}, state}
  end

  def handle_call({:terminate_child, child_id} = msg, from, state) do
    this_name = fully_qualified_name(state.name)

    case Map.get(state.processes, child_id) do
      {^this_name, _child_spec} ->
        reply =
          Horde.DynamicSupervisor.terminate_child_by_id(
            supervisor_name(state.name),
            child_id
          )

        new_state = %{state | processes: Map.delete(state.processes, child_id)}

        :ok = DeltaCrdt.mutate(processes_crdt_name(state.name), :remove, [child_id], :infinity)

        {:reply, reply, new_state}

      {other_node, _child_spec} ->
        proxy_to_node(other_node, msg, from, state)

      nil ->
        case state.distribution_strategy.choose_node(child_id, Map.values(state.members)) do
          {:ok, %{name: ^this_name}} ->
            {:reply, {:error, :not_found}, state}

          {:ok, %{name: other_node_name}} ->
            proxy_to_node(other_node_name, msg, from, state)

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:start_child, _child_spec}, _from, %{shutting_down: true} = state),
    do: {:reply, {:error, {:shutting_down, "this node is shutting down."}}, state}

  def handle_call({:start_child, child_spec} = msg, from, state) do
    this_name = fully_qualified_name(state.name)

    if Map.has_key?(state.processes, child_spec.id) do
      {:reply, {:error, {:already_started, nil}}, state}
    else
      case state.distribution_strategy.choose_node(child_spec.id, Map.values(state.members)) do
        {:ok, %{name: ^this_name}} ->
          {reply, new_state} = add_child(child_spec, state)
          {:reply, reply, new_state}

        {:ok, %{name: other_node_name}} ->
          proxy_to_node(other_node_name, msg, from, state)

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end
  end

  def handle_call(:which_children, _from, state) do
    which_children =
      Enum.flat_map(state.members, fn
        {_, %{name: {name, node}}} ->
          [{supervisor_name(name), node}]
      end)
      |> Enum.flat_map(fn supervisor_name ->
        try do
          Horde.DynamicSupervisor.which_children(supervisor_name)
        catch
          :exit, _ -> []
        end
      end)

    {:reply, which_children, state}
  end

  def handle_call(:count_children, _from, state) do
    count =
      Enum.flat_map(state.members, fn
        {_, %{name: {name, node}}} ->
          [{supervisor_name(name), node}]
      end)
      |> Enum.flat_map(fn supervisor_name ->
        try do
          Horde.DynamicSupervisor.count_children(supervisor_name)
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

  # TODO think of a better name than "disown_child_process"
  def handle_cast({:disown_child_process, child_id}, state) do
    new_state = %{state | processes: Map.delete(state.processes, child_id)}
    :ok = DeltaCrdt.mutate(processes_crdt_name(state.name), :remove, [child_id], :infinity)
    {:noreply, new_state}
  end

  defp proxy_to_node(node_name, message, reply_to, state) do
    case Map.get(state.members, node_name) do
      %{status: :alive} ->
        send(node_name, {:proxy_operation, message, reply_to})
        {:noreply, state}

      _ ->
        {:reply,
         {:error,
          {:node_dead_or_shutting_down,
           "the node responsible for this process is shutting down or dead, try again soon"}},
         state}
    end
  end

  defp set_own_node_status(state, force \\ false)

  defp set_own_node_status(state, true) do
    DeltaCrdt.mutate(
      members_status_crdt_name(state.name),
      :add,
      [fully_qualified_name(state.name), node_info(state)],
      :infinity
    )

    new_members = Map.put(state.members, fully_qualified_name(state.name), node_info(state))

    Map.put(state, :members, new_members)
  end

  defp set_own_node_status(state, false) do
    if Map.get(state.members, fully_qualified_name(state.name)) == node_info(state) do
      state
    else
      set_own_node_status(state, true)
    end
  end

  defp mark_dead(state, name) do
    DeltaCrdt.mutate(
      members_status_crdt_name(state.name),
      :add,
      [name, %Horde.Supervisor.Member{name: name, status: :dead}],
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
  def handle_info({:DOWN, ref, _type, _pid, _reason}, state) do
    case Map.get(state.supervisor_ref_to_name, ref) do
      nil ->
        {:noreply, state}

      name ->
        new_state =
          mark_dead(state, name)
          |> set_own_node_status()
          |> Map.put(:supervisor_ref_to_name, Map.delete(state.supervisor_ref_to_name, ref))
          |> Map.put(:name_to_supervisor_ref, Map.delete(state.name_to_supervisor_ref, name))

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
    processes = DeltaCrdt.read(processes_crdt_name(state.name), 30_000)

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

  def handle_info({:members_updated, reply_to}, state) do
    GenServer.reply(reply_to, :ok)
    {:noreply, update_members(state)}
  end

  def handle_info({:members_status_updated, reply_to}, state) do
    GenServer.reply(reply_to, :ok)
    {:noreply, update_members(state)}
  end

  def handle_info({:set_members, members}, state) do
    {:noreply, set_members(members, state)}
  end

  defp update_members(state) do
    members = DeltaCrdt.read(members_crdt_name(state.name), 30_000)
    members_status = DeltaCrdt.read(members_status_crdt_name(state.name), 30_000)

    members =
      Map.new(members, fn {member, 1} ->
        uninitialized_member = %Horde.Supervisor.Member{
          name: member,
          status: :uninitialized
        }

        {member, Map.get(members_status, member, uninitialized_member)}
      end)

    %{state | members: members}
    |> monitor_supervisors()
    |> set_own_node_status()
    |> handle_quorum_change()
    |> set_crdt_neighbours()
    |> handle_topology_changes()
    |> claim_unclaimed_processes()
  end

  defp member_names(names) do
    Enum.map(names, fn
      {name, node} -> {name, node}
      name when is_atom(name) -> {name, node()}
    end)
  end

  defp set_members(members, state) do
    members = Enum.map(members, &fully_qualified_name/1)

    existing_members = DeltaCrdt.read(members_status_crdt_name(state.name))

    uninitialized_new_members =
      member_names(members)
      |> Map.new(fn name ->
        {name, %Horde.Supervisor.Member{name: name, status: :uninitialized}}
      end)

    new_members =
      Map.merge(
        uninitialized_new_members,
        Map.take(existing_members, Map.keys(uninitialized_new_members))
      )

    new_member_names = Map.keys(new_members) |> MapSet.new()
    existing_member_names = Map.keys(existing_members) |> MapSet.new()

    Enum.each(MapSet.difference(existing_member_names, new_member_names), fn removed_member ->
      DeltaCrdt.mutate_async(members_crdt_name(state.name), :remove, [removed_member])
      DeltaCrdt.mutate_async(members_status_crdt_name(state.name), :remove, [removed_member])
    end)

    Enum.each(MapSet.difference(new_member_names, existing_member_names), fn added_member ->
      DeltaCrdt.mutate_async(members_crdt_name(state.name), :add, [added_member, 1])
    end)

    %{state | members: new_members}
    |> monitor_supervisors()
    |> handle_quorum_change()
    |> set_crdt_neighbours()
    |> handle_topology_changes()
    |> claim_unclaimed_processes()
  end

  defp stop_not_owned_processes(new_state, old_state) do
    this_name = fully_qualified_name(old_state.name)

    old_process_ids =
      Enum.filter(old_state.processes, processes_for_node(this_name))
      |> MapSet.new(fn {id, _rest} -> id end)

    new_process_ids =
      Enum.filter(new_state.processes, processes_for_node(this_name))
      |> MapSet.new(fn {id, _rest} -> id end)

    MapSet.difference(old_process_ids, new_process_ids)
    |> Enum.map(fn id ->
      Horde.DynamicSupervisor.terminate_child_by_id(
        supervisor_name(new_state.name),
        id
      )

      :ok
    end)

    new_state
  end

  defp handle_quorum_change(state) do
    if state.distribution_strategy.has_quorum?(Map.values(state.members)) do
      Enum.each(state.waiting_for_quorum, fn from -> GenServer.reply(from, :ok) end)
      %{state | waiting_for_quorum: []}
    else
      shut_down_all_processes(state)
    end
  end

  defp shut_down_all_processes(state) do
    case Enum.any?(state.processes, processes_for_node(fully_qualified_name(state.name))) do
      false ->
        state

      true ->
        :ok = Horde.DynamicSupervisor.stop(supervisor_name(state.name))
        state
    end
  end

  defp set_crdt_neighbours(state) do
    names = Map.keys(state.members) -- [state.name]

    members_crdt_names = Enum.map(names, fn {name, node} -> {members_crdt_name(name), node} end)

    members_status_crdt_names =
      Enum.map(names, fn {name, node} -> {members_status_crdt_name(name), node} end)

    processes_crdt_names =
      Enum.map(names, fn {name, node} -> {processes_crdt_name(name), node} end)

    send(members_crdt_name(state.name), {:set_neighbours, members_crdt_names})
    send(members_status_crdt_name(state.name), {:set_neighbours, members_status_crdt_names})
    send(processes_crdt_name(state.name), {:set_neighbours, processes_crdt_names})

    state
  end

  defp processes_for_node(node_name) do
    fn
      {_id, {^node_name, _child_spec}} -> true
      _ -> false
    end
  end

  defp handle_topology_changes(state) do
    this_name = fully_qualified_name(state.name)

    {_responses, new_state} =
      processes_on_dead_nodes(state)
      |> Enum.map(fn {_id, {_node, child}} -> child end)
      |> Enum.filter(fn child ->
        case state.distribution_strategy.choose_node(child.id, Map.values(state.members)) do
          {:ok, %{name: ^this_name}} -> true
          _ -> false
        end
      end)
      |> add_children(state)

    new_state
  end

  def processes_on_dead_nodes(%{processes: processes, members: members}) do
    not_dead_nodes =
      Enum.flat_map(members, fn
        {_name, %{status: :dead}} -> []
        {name, _} -> [name]
      end)
      |> MapSet.new()

    procs =
      Enum.reject(processes, fn
        {_id, {node_name, _child_spec}} ->
          MapSet.member?(not_dead_nodes, node_name)
      end)

    if !Enum.empty?(procs) do
      Logger.debug(fn ->
        "Found #{Enum.count(procs)} processes on dead nodes"
      end)
    end

    procs
  end

  defp claim_unclaimed_processes(state) do
    this_name = fully_qualified_name(state.name)

    {_responses, new_state} =
      Enum.flat_map(state.processes, fn
        {id, {nil, child_spec}} ->
          case state.distribution_strategy.choose_node(id, Map.values(state.members)) do
            {:ok, %{name: ^this_name}} -> [child_spec]
            _ -> []
          end

        _ ->
          []
      end)
      |> add_children(state)

    new_state
  end

  defp monitor_supervisors(state) do
    new_supervisor_refs =
      Enum.flat_map(state.members, fn
        {name, %{status: :alive}} ->
          [name]

        _ ->
          []
      end)
      |> Enum.reject(fn name ->
        Map.has_key?(state.name_to_supervisor_ref, name)
      end)
      |> Map.new(fn name ->
        {name, Process.monitor(name)}
      end)

    new_supervisor_ref_to_name =
      Map.merge(
        state.supervisor_ref_to_name,
        Map.new(new_supervisor_refs, fn {k, v} -> {v, k} end)
      )

    new_name_to_supervisor_ref = Map.merge(state.name_to_supervisor_ref, new_supervisor_refs)

    Map.put(state, :supervisor_ref_to_name, new_supervisor_ref_to_name)
    |> Map.put(:name_to_supervisor_ref, new_name_to_supervisor_ref)
  end

  defp update_state_with_child(child, state) do
    :ok =
      DeltaCrdt.mutate(
        processes_crdt_name(state.name),
        :add,
        [child.id, {fully_qualified_name(state.name), child}],
        :infinity
      )

    %{
      state
      | processes: Map.put(state.processes, child.id, {fully_qualified_name(state.name), child})
    }
  end

  defp add_child(child, state) do
    {[response], new_state} = add_children([child], state)
    {response, new_state}
  end

  defp add_children(children, state) do
    Enum.map(children, fn child ->
      case Horde.DynamicSupervisor.start_child(supervisor_name(state.name), child) do
        {:ok, process_pid} ->
          {{:ok, process_pid}, child}

        {:ok, process_pid, term} ->
          {{:ok, process_pid, term}, child}

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
end
