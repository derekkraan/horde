defmodule Horde.DynamicSupervisor.Member do
  @moduledoc false

  @type t :: %Horde.DynamicSupervisor.Member{}
  @type status :: :uninitialized | :alive | :shutting_down | :dead
  defstruct [:status, :name]
end

defmodule Horde.DynamicSupervisorImpl do
  @moduledoc false

  require Logger
  use GenServer
  import Horde.TableUtils

  defstruct name: nil,
            members: %{},
            members_info: %{},
            processes_by_id: nil,
            process_pid_to_id: nil,
            local_process_count: 0,
            waiting_for_quorum: [],
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
    name = Keyword.get(options, :name)

    Logger.info("Starting #{inspect(__MODULE__)} with name #{inspect(name)}")

    Process.flag(:trap_exit, true)

    state =
      %__MODULE__{
        supervisor_options: options,
        processes_by_id: new_table(:processes_by_id),
        process_pid_to_id: new_table(:process_pid_to_id),
        name: name
      }
      |> Map.merge(Map.new(Keyword.take(options, [:distribution_strategy])))

    state = set_own_node_status(state)

    {:ok, state, {:continue, {:set_members, Keyword.get(options, :members)}}}
  end

  def handle_continue({:set_members, nil}, state), do: {:noreply, state}

  def handle_continue({:set_members, :auto}, state) do
    state =
      state.name
      |> Horde.NodeListener.make_members()
      |> set_members(state)

    {:noreply, state}
  end

  def handle_continue({:set_members, members}, state) do
    {:noreply, set_members(members, state)}
  end

  def on_diffs(name, diffs) do
    try do
      send(name, {:crdt_update, diffs})
    rescue
      ArgumentError ->
        # the process might already been stopped
        :ok
    end
  end

  defp node_info(state) do
    %Horde.DynamicSupervisor.Member{
      status: node_status(state),
      name: fully_qualified_name(state.name)
    }
  end

  defp node_status(%{shutting_down: false}), do: :alive
  defp node_status(%{shutting_down: true}), do: :shutting_down

  @doc false
  def handle_call(:horde_shutting_down, _f, state) do
    state =
      %{state | shutting_down: true}
      |> set_own_node_status()

    {:reply, :ok, state}
  end

  def handle_call(:get_telemetry, _from, state) do
    telemetry = %{
      global_supervised_process_count: size_of(state.processes_by_id),
      local_supervised_process_count: state.local_process_count
    }

    {:reply, telemetry, state}
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
    {:reply, Map.keys(state.members), state}
  end

  def handle_call({:terminate_child, child_pid} = msg, from, state) do
    this_name = fully_qualified_name(state.name)

    with child_id when not is_nil(child_id) <- get_item(state.process_pid_to_id, child_pid),
         {^this_name, child, _child_pid} <- get_item(state.processes_by_id, child_id),
         {reply, new_state} <- terminate_child(child, state) do
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

    child_spec = randomize_child_id(child_spec)

    case choose_node(child_spec, state) do
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
          Horde.ProcessesSupervisor.which_children(supervisor_name)
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
          Horde.ProcessesSupervisor.count_children(supervisor_name)
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

  def handle_cast({:update_child_pid, child_id, new_pid}, state) do
    {:noreply, set_child_pid(state, child_id, new_pid)}
  end

  def handle_cast({:relinquish_child_process, child_id}, state) do
    # signal to the rest of the nodes that this process has been relinquished
    # (to the Horde!) by its parent
    {_, child, _} = get_item(state.processes_by_id, child_id)

    DeltaCrdt.put(
      crdt_name(state.name),
      {:process, child.id},
      {nil, child},
      :infinity
    )

    {:noreply, state}
  end

  # TODO think of a better name than "disown_child_process"
  def handle_cast({:disown_child_process, child_id}, state) do
    {{_, _, child_pid}, new_processes_by_id} = pop_item(state.processes_by_id, child_id)

    new_state = %{
      state
      | processes_by_id: new_processes_by_id,
        process_pid_to_id: delete_item(state.process_pid_to_id, child_pid),
        local_process_count: state.local_process_count - 1
    }

    DeltaCrdt.delete(crdt_name(state.name), {:process, child_id}, :infinity)
    {:noreply, new_state}
  end

  defp set_child_pid(state, child_id, new_child_pid) do
    case get_item(state.processes_by_id, child_id) do
      {name, child_spec, old_pid} ->
        DeltaCrdt.put(
          crdt_name(state.name),
          {:process, child_spec.id},
          {fully_qualified_name(state.name), child_spec, new_child_pid},
          :infinity
        )

        new_processes_by_id =
          put_item(state.processes_by_id, child_id, {name, child_spec, new_child_pid})

        new_process_pid_to_id =
          put_item(state.process_pid_to_id, new_child_pid, child_id) |> delete_item(old_pid)

        %{
          state
          | processes_by_id: new_processes_by_id,
            process_pid_to_id: new_process_pid_to_id
        }

      nil ->
        state
    end
  end

  defp randomize_child_id(child) do
    Map.put(child, :id, :rand.uniform(@big_number))
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
    DeltaCrdt.put(
      crdt_name(state.name),
      {:member_node_info, fully_qualified_name(state.name)},
      node_info(state),
      :infinity
    )

    new_members_info =
      Map.put(state.members_info, fully_qualified_name(state.name), node_info(state))

    Map.put(state, :members_info, new_members_info)
  end

  defp mark_dead(state, name) do
    DeltaCrdt.put(
      crdt_name(state.name),
      {:member_node_info, name},
      %Horde.DynamicSupervisor.Member{name: name, status: :dead},
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
      if has_membership_changed?(diffs) do
        monitor_supervisors(new_state)
        |> set_own_node_status()
        |> handle_quorum_change()
        |> set_crdt_neighbours()
        |> handoff_processes()
      else
        new_state
      end

    {:noreply, new_state}
  end

  def has_membership_changed?([{:add, {:member_node_info, _}, _} = _diff | _diffs]), do: true
  def has_membership_changed?([{:remove, {:member_node_info, _}} = _diff | _diffs]), do: true
  def has_membership_changed?([{:add, {:member, _}, _} = _diff | _diffs]), do: true
  def has_membership_changed?([{:remove, {:member, _}} = _diff | _diffs]), do: true

  def has_membership_changed?([_diff | diffs]) do
    has_membership_changed?(diffs)
  end

  def has_membership_changed?([]), do: false

  defp handoff_processes(state) do
    this_node = fully_qualified_name(state.name)

    all_items_values(state.processes_by_id)
    |> Enum.reduce(state, fn {current_node, child_spec, _child_pid}, state ->
      case choose_node(child_spec, state) do
        {:ok, %{name: chosen_node}} ->
          current_member = Map.get(state.members_info, current_node)

          case {current_node, chosen_node} do
            {same_node, same_node} ->
              # process is running on the node on which it belongs

              state

            {^this_node, _other_node} ->
              # process is running here but belongs somewhere else

              case state.supervisor_options[:process_redistribution] do
                :active ->
                  handoff_child(child_spec, state)

                :passive ->
                  state
              end

            {_current_node, ^this_node} ->
              # process is running on another node but belongs here

              case current_member do
                %{status: :dead} ->
                  {_response, state} = add_child(child_spec, state)

                  state

                _ ->
                  state
              end

            {_other_node1, _other_node2} ->
              # process is neither running here nor belongs here

              state
          end

        {:error, _reason} ->
          state
      end
    end)
  end

  defp update_processes(state, [diff | diffs]) do
    update_process(state, diff)
    |> update_processes(diffs)
  end

  defp update_processes(state, []), do: state

  defp update_process(state, {:add, {:process, _child_id}, {nil, child_spec}}) do
    this_name = fully_qualified_name(state.name)

    case choose_node(child_spec, state) do
      {:ok, %{name: ^this_name}} ->
        {_resp, new_state} = add_child(child_spec, state)
        new_state

      {:ok, _} ->
        # matches another node, do nothing
        state

      {:error, _reason} ->
        # error (could be quorum), do nothing
        state
    end
  end

  defp update_process(state, {:add, {:process, child_id}, {node, child_spec, child_pid}}) do
    new_process_pid_to_id =
      case get_item(state.processes_by_id, child_id) do
        {_, _, old_pid} -> delete_item(state.process_pid_to_id, old_pid)
        nil -> state.process_pid_to_id
      end
      |> put_item(child_pid, child_id)

    new_processes_by_id = put_item(state.processes_by_id, child_id, {node, child_spec, child_pid})

    Map.put(state, :processes_by_id, new_processes_by_id)
    |> Map.put(:process_pid_to_id, new_process_pid_to_id)
  end

  defp update_process(state, {:remove, {:process, child_id}}) do
    {value, new_processes_by_id} = pop_item(state.processes_by_id, child_id)

    new_process_pid_to_id =
      case value do
        {_node_name, _child_spec, child_pid} ->
          delete_item(state.process_pid_to_id, child_pid)

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
    %Horde.DynamicSupervisor.Member{status: :uninitialized, name: member}
  end

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
        {name, %Horde.DynamicSupervisor.Member{name: name, status: :uninitialized}}
      end)

    new_members_info =
      Map.merge(
        uninitialized_new_members_info,
        Map.take(state.members_info, Map.keys(uninitialized_new_members_info))
      )

    new_members = Map.new(new_members_info, fn {member, _} -> {member, 1} end)

    new_member_names = Map.keys(new_members_info) |> MapSet.new()
    existing_member_names = Map.keys(state.members) |> MapSet.new()

    keys_to_remove =
      MapSet.difference(existing_member_names, new_member_names)
      |> Enum.flat_map(fn removed_member ->
        [{:member, removed_member}, {:member_node_info, removed_member}]
      end)

    DeltaCrdt.drop(
      crdt_name(state.name),
      keys_to_remove,
      :infinity
    )

    map_to_add =
      MapSet.difference(new_member_names, existing_member_names)
      |> Map.new(fn added_member -> {{:member, added_member}, 1} end)

    DeltaCrdt.merge(crdt_name(state.name), map_to_add, :infinity)

    %{state | members: new_members, members_info: new_members_info}
    |> monitor_supervisors()
    |> handle_quorum_change()
    |> set_crdt_neighbours()
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
    case any_item(state.processes_by_id, processes_for_node(fully_qualified_name(state.name))) do
      false ->
        state

      true ->
        :ok = Horde.ProcessesSupervisor.stop(supervisor_name(state.name))
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
    DeltaCrdt.put(
      crdt_name(state.name),
      {:process, child.id},
      {fully_qualified_name(state.name), child, child_pid},
      :infinity
    )

    new_processes_by_id =
      put_item(
        state.processes_by_id,
        child.id,
        {fully_qualified_name(state.name), child, child_pid}
      )

    new_process_pid_to_id = put_item(state.process_pid_to_id, child_pid, child.id)
    new_local_process_count = state.local_process_count + 1

    Map.put(state, :processes_by_id, new_processes_by_id)
    |> Map.put(:process_pid_to_id, new_process_pid_to_id)
    |> Map.put(:local_process_count, new_local_process_count)
  end

  defp handoff_child(child, state) do
    {_, _, child_pid} = get_item(state.processes_by_id, child.id)

    # we send a special exit signal to the process here.
    # when the process has exited, Horde.ProcessSupervisor
    # will cast `{:relinquish_child_process, child_id}`
    # to this process for cleanup.

    Horde.ProcessesSupervisor.send_exit_signal(
      supervisor_name(state.name),
      child_pid,
      {:shutdown, :process_redistribution}
    )

    new_state = Map.put(state, :local_process_count, state.local_process_count - 1)

    new_state
  end

  defp terminate_child(child, state) do
    child_id = child.id

    reply =
      Horde.ProcessesSupervisor.terminate_child_by_id(
        supervisor_name(state.name),
        child_id
      )

    new_state =
      Map.put(state, :processes_by_id, delete_item(state.processes_by_id, child_id))
      |> Map.put(:local_process_count, state.local_process_count - 1)

    DeltaCrdt.delete(crdt_name(state.name), {:process, child_id}, :infinity)

    {reply, new_state}
  end

  defp add_child(child, state) do
    {[response], new_state} = add_children([child], state)
    {response, new_state}
  end

  defp add_children(children, state) do
    Enum.map(children, fn child_spec ->
      case Horde.ProcessesSupervisor.start_child(supervisor_name(state.name), child_spec) do
        {:ok, child_pid} ->
          {{:ok, child_pid}, child_spec}

        {:ok, child_pid, term} ->
          {{:ok, child_pid, term}, child_spec}

        {:error, error} ->
          {:error, error}

        :ignore ->
          :ignore
      end
    end)
    |> Enum.reduce({[], state}, fn
      {{:ok, child_pid} = resp, child_spec}, {responses, state} ->
        {[resp | responses], update_state_with_child(child_spec, child_pid, state)}

      {{:ok, child_pid, _term} = resp, child_spec}, {responses, state} ->
        {[resp | responses], update_state_with_child(child_spec, child_pid, state)}

      {:error, error}, {responses, state} ->
        {[{:error, error} | responses], state}

      :ignore, {responses, state} ->
        {[:ignore | responses], state}
    end)
  end

  defp choose_node(child_spec, state) do
    distribution_id = :erlang.phash2(Map.drop(child_spec, [:id]))

    state.distribution_strategy.choose_node(
      distribution_id,
      Map.values(members(state))
    )
  end

  defp members(state) do
    Map.take(state.members_info, Map.keys(state.members))
  end
end
