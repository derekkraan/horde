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
            members_info: %{},
            processes_by_id: %{},
            process_pid_to_id: %{},
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
  defp crdt_name(name), do: :"#{name}.Crdt"
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
      crdt_name(state.name),
      :add,
      [{:member_node_info, fully_qualified_name(state.name)}, node_info(state)],
      :infinity
    )

    {:reply, :ok, state}
  end

  def handle_call(:wait_for_quorum, from, state) do
    if state.distribution_strategy.has_quorum?(Map.values(members(state))) do
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

  def handle_call({:terminate_child, child_pid} = msg, from, state) do
    this_name = fully_qualified_name(state.name)

    with child_id when not is_nil(child_id) <- Map.get(state.process_pid_to_id, child_pid),
         {^this_name, _child_spec, _child_pid} <- Map.get(state.processes_by_id, child_id) do
      reply =
        Horde.DynamicSupervisor.terminate_child_by_id(
          supervisor_name(state.name),
          child_id
        )

      new_state = %{state | processes_by_id: Map.delete(state.processes_by_id, child_id)}

      :ok = DeltaCrdt.mutate(crdt_name(state.name), :remove, [{:process, child_id}], :infinity)

      {:reply, reply, new_state}
    else
      {other_node, _child_spec, _child_pid} ->
        proxy_to_node(other_node, msg, from, state)

      nil ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:start_child, _child_spec}, _from, %{shutting_down: true} = state),
    do: {:reply, {:error, {:shutting_down, "this node is shutting down."}}, state}

  @big_number round(:math.pow(2, 128))

  def handle_call({:start_child, child_spec} = msg, from, state) do
    this_name = fully_qualified_name(state.name)

    child_spec = Map.put(child_spec, :id, :rand.uniform(@big_number))

    case state.distribution_strategy.choose_node(
           child_spec.id,
           Map.values(members(state))
         ) do
      {:ok, %{name: ^this_name}} ->
        {reply, new_state} = add_child(child_spec, state)
        {:reply, reply, new_state}

      {:ok, %{name: other_node_name}} ->
        proxy_to_node(other_node_name, msg, from, state)

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:which_children, _from, state) do
    which_children =
      Enum.flat_map(members(state), fn
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
      |> Enum.map(fn {_id, pid, type, module} -> {:undefined, pid, type, module} end)

    {:reply, which_children, state}
  end

  def handle_call(:count_children, _from, state) do
    count =
      Enum.flat_map(members(state), fn
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

  def handle_call({:update_child_pid, child_id, new_pid}, _from, state) do
    {:reply, :ok, set_child_pid(state, child_id, new_pid)}
  end

  defp set_child_pid(state, child_id, new_child_pid) do
    case Map.get(state.processes_by_id, child_id) do
      {name, child, old_pid} ->
        :ok =
          DeltaCrdt.mutate(
            crdt_name(state.name),
            :add,
            [{:process, child.id}, {fully_qualified_name(state.name), child, new_child_pid}],
            :infinity
          )

        new_processes_by_id =
          Map.put(state.processes_by_id, child_id, {name, child, new_child_pid})

        new_process_pid_to_id =
          Map.put(state.process_pid_to_id, new_child_pid, child_id) |> Map.delete(old_pid)

        %{
          state
          | processes_by_id: new_processes_by_id,
            process_pid_to_id: new_process_pid_to_id
        }

      nil ->
        state
    end
  end

  # TODO think of a better name than "disown_child_process"
  def handle_cast({:disown_child_process, child_id}, state) do
    {{_, _, child_pid}, new_processes_by_id} = Map.pop(state.processes_by_id, child_id)

    new_state = %{
      state
      | processes_by_id: new_processes_by_id,
        process_pid_to_id: Map.delete(state.process_pid_to_id, child_pid)
    }

    :ok = DeltaCrdt.mutate(crdt_name(state.name), :remove, [{:process, child_id}], :infinity)
    {:noreply, new_state}
  end

  defp proxy_to_node(node_name, message, reply_to, state) do
    case Map.get(members(state), node_name) do
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

  defp set_own_node_status(state, false) do
    if Map.get(state.members_info, fully_qualified_name(state.name)) == node_info(state) do
      state
    else
      set_own_node_status(state, true)
    end
  end

  defp set_own_node_status(state, true) do
    DeltaCrdt.mutate(
      crdt_name(state.name),
      :add,
      [{:member_node_info, fully_qualified_name(state.name)}, node_info(state)],
      :infinity
    )

    new_members_info =
      Map.put(state.members_info, fully_qualified_name(state.name), node_info(state))

    Map.put(state, :members_info, new_members_info)
  end

  defp mark_dead(state, name) do
    DeltaCrdt.mutate(
      crdt_name(state.name),
      :add,
      [{:member_node_info, name}, %Horde.Supervisor.Member{name: name, status: :dead}],
      :infinity
    )

    state
  end

  def handle_info({:set_members, members}, state) do
    {:noreply, set_members(members, state)}
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

  def handle_info({:crdt_update, diffs}, state) do
    new_state =
      update_members(state, diffs)
      |> update_processes(diffs)

    new_state =
      if has_membership_change?(diffs) do
        monitor_supervisors(new_state)
        |> set_own_node_status()
        |> handle_quorum_change()
        |> set_crdt_neighbours()
        |> handle_dead_nodes()
      else
        new_state
      end

    {:noreply, new_state}
  end

  def has_membership_change?([{:add, {:member_node_info, _}, _} | _diffs]), do: true

  def has_membership_change?([{:remove, {:member_node_info, _}} | _diffs]), do: true

  def has_membership_change?([{:add, {:member, _}, _} | _diffs]), do: true

  def has_membership_change?([{:remove, {:member, _}} | _diffs]), do: true

  def has_membership_change?([_diff | diffs]) do
    has_membership_change?(diffs)
  end

  def has_membership_change?([]), do: false

  defp update_processes(state, [diff | diffs]) do
    update_process(state, diff)
    |> update_processes(diffs)
  end

  defp update_processes(state, []), do: state

  defp update_process(state, {:add, {:process, child_id}, {nil, child_spec}}) do
    this_name = fully_qualified_name(state.name)

    case state.distribution_strategy.choose_node(child_id, Map.values(members(state))) do
      {:ok, %{name: ^this_name}} ->
        {_resp, state} = add_child(child_spec, state)
        state

      _ ->
        state
    end
  end

  defp update_process(state, {:add, {:process, child_id}, {node, child_spec, child_pid}}) do
    this_node = fully_qualified_name(state.name)

    case {Map.get(state.processes_by_id, child_id), node} do
      {{^this_node, _child_spec, _child_pid}, ^this_node} ->
        nil

      {{^this_node, _child_spec, _child_pid}, _other_node} ->
        Horde.DynamicSupervisor.terminate_child_by_id(supervisor_name(state.name), child_id)

      _ ->
        nil
    end

    new_process_pid_to_id =
      case Map.get(state.processes_by_id, child_id) do
        {_, _, old_pid} -> Map.delete(state.process_pid_to_id, old_pid)
        nil -> state.process_pid_to_id
      end
      |> Map.put(child_pid, child_id)

    new_processes_by_id = Map.put(state.processes_by_id, child_id, {node, child_spec, child_pid})

    Map.put(state, :processes_by_id, new_processes_by_id)
    |> Map.put(:process_pid_to_id, new_process_pid_to_id)
  end

  defp update_process(state, {:remove, {:process, child_id}}) do
    {value, new_processes_by_id} = Map.pop(state.processes_by_id, child_id)

    new_process_pid_to_id =
      case value do
        {_node_name, _child_spec, child_pid} ->
          Map.delete(state.process_pid_to_id, child_pid)

        nil ->
          state.process_pid_to_id
      end

    Map.put(state, :processes_by_id, new_processes_by_id)
    |> Map.put(:process_pid_to_id, new_process_pid_to_id)
  end

  defp update_process(state, _), do: state

  defp update_members(state, [diff | diffs]) do
    update_member(state, diff)
    |> update_members(diffs)
  end

  defp update_members(state, []), do: state

  defp update_member(state, {:add, {:member, member}, 1}) do
    new_members = Map.put_new(state.members, member, 1)
    new_members_info = Map.put_new(state.members_info, member, uninitialized_member(member))

    Map.put(state, :members, new_members)
    |> Map.put(:members_info, new_members_info)
  end

  defp update_member(state, {:remove, {:member, member}}) do
    new_members = Map.delete(state.members, member)

    Map.put(state, :members, new_members)
  end

  defp update_member(state, {:add, {:member_node_info, member}, node_info}) do
    new_members = Map.put(state.members_info, member, node_info)

    Map.put(state, :members_info, new_members)
  end

  defp update_member(state, {:remove, {:member_node_info, member}}) do
    new_members = Map.delete(state.members_info, member)

    Map.put(state, :members_info, new_members)
  end

  defp update_member(state, _), do: state

  defp uninitialized_member(member) do
    %Horde.Supervisor.Member{status: :uninitialized, name: member}
  end

  defp handle_dead_nodes(state) do
    not_dead_members =
      Enum.flat_map(members(state), fn
        {_, %{status: :dead}} -> []
        {not_dead, _} -> [not_dead]
      end)
      |> MapSet.new()

    check_processes(state, Map.values(state.processes_by_id), not_dead_members)
  end

  defp check_processes(state, [{member, child, _child_pid} | procs], not_dead_members) do
    this_name = fully_qualified_name(state.name)

    with false <- MapSet.member?(not_dead_members, member),
         {:ok, %{name: ^this_name}} <-
           state.distribution_strategy.choose_node(
             child.id,
             Map.values(members(state))
           ),
         {_result, state} <- add_child(child, state) do
      state
    else
      _ -> state
    end
    |> check_processes(procs, not_dead_members)
  end

  defp check_processes(state, [], _), do: state

  defp member_names(names) do
    Enum.map(names, fn
      {name, node} -> {name, node}
      name when is_atom(name) -> {name, node()}
    end)
  end

  defp set_members(members, state) do
    members = Enum.map(members, &fully_qualified_name/1)

    uninitialized_new_members_info =
      member_names(members)
      |> Map.new(fn name ->
        {name, %Horde.Supervisor.Member{name: name, status: :uninitialized}}
      end)

    new_members_info =
      Map.merge(
        uninitialized_new_members_info,
        Map.take(state.members_info, Map.keys(uninitialized_new_members_info))
      )

    new_members = Map.new(new_members_info, fn {member, _} -> {member, 1} end)

    new_member_names = Map.keys(new_members_info) |> MapSet.new()
    existing_member_names = Map.keys(state.members) |> MapSet.new()

    Enum.each(MapSet.difference(existing_member_names, new_member_names), fn removed_member ->
      DeltaCrdt.mutate(crdt_name(state.name), :remove, [{:member, removed_member}], :infinity)

      DeltaCrdt.mutate(
        crdt_name(state.name),
        :remove,
        [{:member_node_info, removed_member}],
        :infinity
      )
    end)

    Enum.each(MapSet.difference(new_member_names, existing_member_names), fn added_member ->
      DeltaCrdt.mutate(crdt_name(state.name), :add, [{:member, added_member}, 1], :infinity)
    end)

    %{state | members: new_members, members_info: new_members_info}
    |> monitor_supervisors()
    |> handle_quorum_change()
    |> set_crdt_neighbours()
    |> handle_dead_nodes()
  end

  defp handle_quorum_change(state) do
    if state.distribution_strategy.has_quorum?(Map.values(members(state))) do
      Enum.each(state.waiting_for_quorum, fn from -> GenServer.reply(from, :ok) end)
      %{state | waiting_for_quorum: []}
    else
      shut_down_all_processes(state)
    end
  end

  defp shut_down_all_processes(state) do
    case Enum.any?(state.processes_by_id, processes_for_node(fully_qualified_name(state.name))) do
      false ->
        state

      true ->
        :ok = Horde.DynamicSupervisor.stop(supervisor_name(state.name))
        state
    end
  end

  defp set_crdt_neighbours(state) do
    names = Map.keys(state.members) -- [fully_qualified_name(state.name)]

    crdt_names = Enum.map(names, fn {name, node} -> {crdt_name(name), node} end)

    send(crdt_name(state.name), {:set_neighbours, crdt_names})

    state
  end

  defp processes_for_node(node_name) do
    fn
      {_id, {^node_name, _child_spec, _child_pid}} -> true
      _ -> false
    end
  end

  defp monitor_supervisors(state) do
    new_supervisor_refs =
      Enum.flat_map(members(state), fn
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

  defp update_state_with_child(child, child_pid, state) do
    :ok =
      DeltaCrdt.mutate(
        crdt_name(state.name),
        :add,
        [{:process, child.id}, {fully_qualified_name(state.name), child, child_pid}],
        :infinity
      )

    new_processes_by_id =
      Map.put(
        state.processes_by_id,
        child.id,
        {fully_qualified_name(state.name), child, child_pid}
      )

    new_process_pid_to_id = Map.put(state.process_pid_to_id, child_pid, child.id)

    Map.put(state, :processes_by_id, new_processes_by_id)
    |> Map.put(:process_pid_to_id, new_process_pid_to_id)
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
      {{:ok, child_pid} = resp, child}, {responses, state} ->
        {[resp | responses], update_state_with_child(child, child_pid, state)}

      {{:ok, child_pid, _term} = resp, child}, {responses, state} ->
        {[resp | responses], update_state_with_child(child, child_pid, state)}

      {:error, error}, {responses, state} ->
        {[{:error, error} | responses], state}
    end)
  end

  defp members(state) do
    Map.take(state.members_info, Map.keys(state.members))
  end
end
