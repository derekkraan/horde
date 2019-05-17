defmodule Horde.RegistryImpl do
  @moduledoc false

  use GenServer

  require Logger

  defmodule State do
    @moduledoc false
    defstruct name: nil,
              nodes: MapSet.new(),
              members: MapSet.new(),
              processes_updated_counter: 0,
              processes_updated_at: 0,
              registry_ets_table: nil,
              pids_ets_table: nil,
              keys_ets_table: nil,
              members_ets_table: nil
  end

  @spec child_spec(options :: list()) :: Supervisor.child_spec()
  def child_spec(options \\ []) do
    %{
      id: Keyword.get(options, :name, __MODULE__),
      start: {__MODULE__, :start_link, [options]}
    }
  end

  @spec start_link(options :: list()) :: GenServer.on_start()
  def start_link(options \\ []) do
    name = Keyword.get(options, :name)

    if !is_atom(name) || is_nil(name) do
      raise ArgumentError, "expected :name to be given and to be an atom, got: #{inspect(name)}"
    end

    GenServer.start_link(__MODULE__, options, name: name)
  end

  ### GenServer callbacks

  def init(opts) do
    {:ok, opts} =
      case Keyword.get(opts, :init_module) do
        nil -> {:ok, opts}
        module -> module.init(opts)
      end

    Process.flag(:trap_exit, true)

    name = Keyword.get(opts, :name)
    pids_name = :"pids_#{name}"
    keys_name = :"keys_#{name}"
    members_name = :"members_#{name}"

    Logger.info("Starting #{inspect(__MODULE__)} with name #{inspect(name)}")

    unless is_atom(name) do
      raise ArgumentError, "expected :name to be given and to be an atom, got: #{inspect(name)}"
    end

    :ets.new(name, [:named_table, {:read_concurrency, true}])
    :ets.new(pids_name, [:named_table, {:read_concurrency, true}])
    :ets.new(keys_name, [:named_table, {:read_concurrency, true}])
    :ets.new(members_name, [:named_table, {:read_concurrency, true}])

    state = %State{
      name: name,
      registry_ets_table: name,
      pids_ets_table: pids_name,
      keys_ets_table: keys_name,
      members_ets_table: members_name
    }

    state =
      case Keyword.get(opts, :members) do
        nil ->
          state

        members ->
          members = Enum.map(members, &fully_qualified_name/1)

          Enum.each(members, fn member ->
            DeltaCrdt.mutate(crdt_name(state.name), :add, [{:member, member}, 1], :infinity)
            :ets.insert(state.members_ets_table, {member, 1})
          end)

          neighbours =
            List.delete(members, [fully_qualified_name(state.name)])
            |> crdt_names()

          send(crdt_name(state.name), {:set_neighbours, neighbours})

          %{state | nodes: Enum.map(members, fn {_name, node} -> node end) |> MapSet.new()}
      end

    case Keyword.get(opts, :meta) do
      nil ->
        nil

      meta ->
        Enum.each(meta, fn {key, value} -> put_meta(state, key, value) end)
    end

    {:ok, state}
  end

  def handle_info({:crdt_update, diffs}, state) do
    new_state = process_diffs(state, diffs)
    {:noreply, new_state}
  end

  def handle_info({:EXIT, pid, reason}, state) do
    case :ets.take(state.pids_ets_table, pid) do
      [{_pid, keys}] ->
        Enum.each(keys, fn key ->
          DeltaCrdt.mutate(crdt_name(state.name), :remove, [{:key, key}], :infinity)
          :ets.match_delete(state.keys_ets_table, {key, :_, {pid, :_}})
        end)

      _ ->
        nil
    end

    {:noreply, state}
  end

  defp process_diffs(state, [diff | diffs]) do
    process_diff(state, diff)
    |> process_diffs(diffs)
  end

  defp process_diffs(state, []), do: state

  defp process_diff(state, {:add, {:member, member}, 1}) do
    new_members = MapSet.put(state.members, member)

    :ets.insert(state.members_ets_table, {member, 1})

    neighbours =
      MapSet.delete(new_members, fully_qualified_name(state.name))
      |> crdt_names()

    send(crdt_name(state.name), {:set_neighbours, neighbours})

    new_nodes = Enum.map(new_members, fn {_name, node} -> node end) |> MapSet.new()

    %{state | members: new_members, nodes: new_nodes}
  end

  defp process_diff(state, {:remove, {:member, member}}) do
    :ets.match_delete(state.members_ets_table, {member, 1})

    new_members = MapSet.delete(state.members, member)
    new_nodes = Enum.map(new_members, fn {_name, node} -> node end) |> MapSet.new()

    %{state | members: new_members, nodes: new_nodes}
  end

  defp process_diff(state, {:add, {:key, key}, {member, pid, value}}) do
    link_local_pid(pid)

    add_key_to_pids_table(state, pid, key)

    with [{^key, _member, {other_pid, other_value}}] when other_pid != pid <-
           :ets.lookup(state.keys_ets_table, key) do
      # There was a conflict in the name registry, send the  losing PID
      # an exit signal indicating it has lost the name registration.
      remove_key_from_pids_table(state, other_pid, key)
      Process.exit(other_pid, {:name_conflict, {key, other_value}, state.name, pid})
    end

    :ets.insert(state.keys_ets_table, {key, member, {pid, value}})
    state
  end

  defp process_diff(state, {:remove, {:key, key}}) do
    case :ets.lookup(state.keys_ets_table, key) do
      [] ->
        nil

      [{key, _member, {pid, _val}}] ->
        remove_key_from_pids_table(state, pid, key)
    end

    :ets.match_delete(state.keys_ets_table, {key, :_, :_})
    state
  end

  defp process_diff(state, {:add, {:registry, key}, value}) do
    :ets.insert(state.registry_ets_table, {key, value})
    state
  end

  defp add_key_to_pids_table(state, pid, key) do
    case :ets.lookup(state.pids_ets_table, pid) do
      [] ->
        :ets.insert(state.pids_ets_table, {pid, [key]})

      [{^pid, keys}] ->
        :ets.insert(state.pids_ets_table, {pid, Enum.uniq([key | keys])})
    end
  end

  defp remove_key_from_pids_table(state, pid, key) do
    case :ets.lookup(state.pids_ets_table, pid) do
      [] ->
        :ok

      [{^pid, keys}] ->
        case List.delete(keys, key) do
          [] ->
            :ets.match_delete(state.pids_ets_table, {pid, :_})

          new_keys ->
            :ets.insert(state.pids_ets_table, {pid, new_keys})
        end
    end
  end

  defp link_local_pid(pid) when node(pid) == node() do
    Process.link(pid)
  end

  defp link_local_pid(_pid), do: nil

  def handle_call({:set_members, members}, _from, state) do
    new_members = MapSet.new(member_names(members))

    Enum.each(MapSet.difference(state.members, new_members), fn removed_member ->
      DeltaCrdt.mutate(crdt_name(state.name), :remove, [{:member, removed_member}], :infinity)
    end)

    Enum.each(MapSet.difference(new_members, state.members), fn added_member ->
      DeltaCrdt.mutate(crdt_name(state.name), :add, [{:member, added_member}, 1], :infinity)
    end)

    neighbours =
      MapSet.delete(new_members, fully_qualified_name(state.name))
      |> crdt_names()

    send(crdt_name(state.name), {:set_neighbours, neighbours})

    {:reply, :ok, %{state | members: new_members}}
  end

  def handle_call({:register, key, value, pid}, _from, state) do
    Process.link(pid)

    DeltaCrdt.mutate(
      crdt_name(state.name),
      :add,
      [{:key, key}, {fully_qualified_name(state.name), pid, value}],
      :infinity
    )

    add_key_to_pids_table(state, pid, key)

    :ets.insert(state.keys_ets_table, {key, fully_qualified_name(state.name), {pid, value}})

    {:reply, {:ok, self()}, state}
  end

  def handle_call({:update_value, key, pid, value}, _from, state) do
    DeltaCrdt.mutate(
      crdt_name(state.name),
      :add,
      [{:key, key}, {fully_qualified_name(state.name), pid, value}],
      :infinity
    )

    :ets.insert(state.keys_ets_table, {key, fully_qualified_name(state.name), {pid, value}})

    {:reply, :ok, state}
  end

  def handle_call({:unregister, key, pid}, _from, state) do
    DeltaCrdt.mutate(crdt_name(state.name), :remove, [{:key, key}], :infinity)

    remove_key_from_pids_table(state, pid, key)

    :ets.match_delete(state.keys_ets_table, {key, :_, {pid, :_}})

    {:reply, :ok, state}
  end

  def handle_call({:put_meta, key, value}, _from, state) do
    put_meta(state, key, value)

    {:reply, :ok, state}
  end

  def handle_call(:members, _from, state) do
    {:reply, {:ok, MapSet.to_list(state.members)}, state}
  end

  defp member_names(names) do
    Enum.map(names, fn
      {name, node} -> {name, node}
      name when is_atom(name) -> {name, node()}
    end)
  end

  defp crdt_names(names) do
    Enum.map(names, fn {name, node} -> {crdt_name(name), node} end)
  end

  defp crdt_name(name), do: :"#{name}.Crdt"

  defp fully_qualified_name({name, node}) when is_atom(name) and is_atom(node), do: {name, node}
  defp fully_qualified_name(name) when is_atom(name), do: {name, node()}

  defp put_meta(state, key, value) do
    DeltaCrdt.mutate(crdt_name(state.name), :add, [{:registry, key}, value], :infinity)

    :ets.insert(state.registry_ets_table, {key, value})
  end
end
