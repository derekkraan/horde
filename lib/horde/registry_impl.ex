defmodule Horde.RegistryImpl do
  @moduledoc false

  require Logger

  defmodule State do
    @moduledoc false
    defstruct name: nil,
              nodes: MapSet.new(),
              processes_updated_counter: 0,
              processes_updated_at: 0,
              registry_ets_table: nil,
              pids_ets_table: nil,
              keys_ets_table: nil
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

  def terminate(_reason, state) do
    DeltaCrdt.mutate_async(members_crdt_name(state.name), :remove, [
      fully_qualified_name(state.name)
    ])
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

    Logger.info("Starting #{inspect(__MODULE__)} with name #{inspect(name)}")

    unless is_atom(name) do
      raise ArgumentError, "expected :name to be given and to be an atom, got: #{inspect(name)}"
    end

    :ets.new(name, [:named_table, {:read_concurrency, true}])
    :ets.new(pids_name, [:named_table, {:read_concurrency, true}])
    :ets.new(keys_name, [:named_table, {:read_concurrency, true}])

    state = %State{
      name: name,
      registry_ets_table: name,
      pids_ets_table: pids_name,
      keys_ets_table: keys_name
    }

    mark_alive(state)

    case Keyword.get(opts, :members) do
      nil ->
        nil

      members ->
        members = Enum.map(members, &fully_qualified_name/1)

        Enum.each(members, fn member ->
          DeltaCrdt.mutate_async(members_crdt_name(state.name), :add, [member, 1])
        end)

        neighbours = members -- [fully_qualified_name(state.name)]

        send(members_crdt_name(state.name), {:set_neighbours, members_crdt_names(neighbours)})
        send(registry_crdt_name(state.name), {:set_neighbours, registry_crdt_names(neighbours)})
        send(keys_crdt_name(state.name), {:set_neighbours, keys_crdt_names(neighbours)})
    end

    case Keyword.get(opts, :meta) do
      nil ->
        nil

      meta ->
        Enum.each(meta, fn {key, value} -> put_meta(state, key, value) end)
    end

    {:ok, state}
  end

  defp mark_alive(state) do
    DeltaCrdt.mutate_async(members_crdt_name(state.name), :add, [
      fully_qualified_name(state.name),
      1
    ])
  end

  defp mark_dead(state, n) do
    members = DeltaCrdt.read(members_crdt_name(state.name), 30_000)

    Enum.each(members, fn
      {_name, ^n} = member ->
        DeltaCrdt.mutate_async(members_crdt_name(state.name), :remove, [member])

      _ ->
        nil
    end)
  end

  def handle_info({:registry_updated, reply_to}, state) do
    registry = DeltaCrdt.read(registry_crdt_name(state.name), 30_000)
    sync_ets_table(state.registry_ets_table, registry)
    GenServer.reply(reply_to, :ok)
    {:noreply, state}
  end

  def handle_info({:keys_updated, reply_to}, state) do
    keys = DeltaCrdt.read(keys_crdt_name(state.name), 30_000)
    link_own_pids(keys)
    sync_ets_table(state.pids_ets_table, invert_keys(keys))
    sync_ets_table(state.keys_ets_table, keys)
    GenServer.reply(reply_to, :ok)
    {:noreply, state}
  end

  def handle_info({:members_updated, reply_to}, state) do
    members =
      DeltaCrdt.read(members_crdt_name(state.name), 30_000)
      |> Map.keys()

    members = members -- [state.name]

    nodes =
      Enum.map(members, fn {_name, node} -> node end)
      |> Enum.uniq()

    monitor_new_nodes(nodes, state)

    send(members_crdt_name(state.name), {:set_neighbours, members_crdt_names(members)})
    send(registry_crdt_name(state.name), {:set_neighbours, registry_crdt_names(members)})
    send(keys_crdt_name(state.name), {:set_neighbours, keys_crdt_names(members)})

    GenServer.reply(reply_to, :ok)

    {:noreply, Map.put(state, :nodes, nodes)}
  end

  def handle_info({:EXIT, pid, _reason}, state) do
    case :ets.take(state.pids_ets_table, pid) do
      [{_pid, keys}] ->
        Enum.each(keys, fn key ->
          DeltaCrdt.mutate_async(keys_crdt_name(state.name), :remove, [key])
          :ets.match_delete(state.keys_ets_table, {key, {pid, :_}})
        end)

      _ ->
        nil
    end

    {:noreply, state}
  end

  def handle_info({:nodedown, n}, state) do
    mark_alive(state)
    mark_dead(state, n)

    Enum.each(DeltaCrdt.read(keys_crdt_name(state.name), 30_000), fn
      {key, {pid, _value}} when node(pid) == n ->
        DeltaCrdt.mutate_async(keys_crdt_name(state.name), :remove, [key])
        :ets.match_delete(state.keys_ets_table, {key, {pid, :_}})

      {key, {pid, value}} when node(pid) == node() ->
        DeltaCrdt.mutate_async(keys_crdt_name(state.name), :add, [key, {pid, value}])

      _another_node ->
        nil
    end)

    new_nodes =
      Enum.filter(state.nodes, fn
        ^n -> false
        _ -> true
      end)

    {:noreply, Map.put(state, :nodes, new_nodes)}
  end

  def handle_call({:set_members, members}, _from, state) do
    existing_members = DeltaCrdt.read(members_crdt_name(state.name)) |> MapSet.new()
    new_members = member_names(members) |> MapSet.new()

    Enum.each(MapSet.difference(existing_members, new_members), fn removed_member ->
      DeltaCrdt.mutate_async(members_crdt_name(state.name), :remove, [removed_member])
    end)

    Enum.each(MapSet.difference(new_members, existing_members), fn added_member ->
      DeltaCrdt.mutate_async(members_crdt_name(state.name), :add, [added_member, 1])
    end)

    neighbours = MapSet.difference(new_members, MapSet.new([state.name]))

    send(members_crdt_name(state.name), {:set_neighbours, members_crdt_names(neighbours)})
    send(registry_crdt_name(state.name), {:set_neighbours, registry_crdt_names(neighbours)})
    send(keys_crdt_name(state.name), {:set_neighbours, keys_crdt_names(neighbours)})

    {:reply, :ok, state}
  end

  def handle_call(:get_registry_ets_table, _from, %{registry_ets_table: t} = state),
    do: {:reply, t, state}

  def handle_call(:get_pids_ets_table, _from, %{pids_ets_table: t} = state),
    do: {:reply, t, state}

  def handle_call(:get_keys_ets_table, _from, %{keys_ets_table: t} = state),
    do: {:reply, t, state}

  def handle_call({:register, key, value, pid}, _from, state) do
    Process.link(pid)

    DeltaCrdt.mutate_async(keys_crdt_name(state.name), :add, [key, {pid, value}])

    case :ets.lookup(state.pids_ets_table, pid) do
      [] ->
        :ets.insert(state.pids_ets_table, {pid, [key]})

      [{_pid, keys}] ->
        :ets.insert(state.pids_ets_table, {pid, [key | keys]})
    end

    :ets.insert(state.keys_ets_table, {key, {pid, value}})

    {:reply, {:ok, self()}, state}
  end

  def handle_call({:update_value, key, pid, value}, _from, state) do
    DeltaCrdt.mutate_async(keys_crdt_name(state.name), :add, [key, {pid, value}])

    :ets.insert(state.keys_ets_table, {key, {pid, value}})

    {:reply, :ok, state}
  end

  def handle_call({:unregister, key, pid}, _from, state) do
    DeltaCrdt.mutate_async(keys_crdt_name(state.name), :remove, [key])

    case :ets.lookup(state.pids_ets_table, pid) do
      [] -> []
      [{pid, keys}] -> :ets.insert(state.pids_ets_table, {pid, List.delete(keys, key)})
    end

    :ets.match_delete(state.keys_ets_table, {key, {pid, :_}})

    {:reply, :ok, state}
  end

  def handle_call({:put_meta, key, value}, _from, state) do
    put_meta(state, key, value)

    {:reply, :ok, state}
  end

  def handle_call(:members, _from, state) do
    {:reply, {:ok, Map.keys(DeltaCrdt.read(members_crdt_name(state.name), 30_000))}, state}
  end

  defp member_names(names) do
    Enum.map(names, fn
      {name, node} -> {name, node}
      name when is_atom(name) -> {name, node()}
    end)
  end

  defp members_crdt_names(names) do
    Enum.map(names, fn {name, node} -> {members_crdt_name(name), node} end)
  end

  defp registry_crdt_names(names) do
    Enum.map(names, fn {name, node} -> {registry_crdt_name(name), node} end)
  end

  defp keys_crdt_names(names) do
    Enum.map(names, fn {name, node} -> {keys_crdt_name(name), node} end)
  end

  defp members_crdt_name(name), do: :"#{name}.MembersCrdt"
  defp registry_crdt_name(name), do: :"#{name}.RegistryCrdt"
  defp keys_crdt_name(name), do: :"#{name}.KeysCrdt"

  defp fully_qualified_name({name, node}) when is_atom(name) and is_atom(node), do: {name, node}
  defp fully_qualified_name(name) when is_atom(name), do: {name, node()}

  defp link_own_pids(keys) do
    Enum.each(keys, fn
      {_key, {pid, _val}} when node(pid) == node() ->
        Process.link(pid)

      _ ->
        nil
    end)
  end

  defp monitor_new_nodes(nodes, %{nodes: state_nodes}) do
    MapSet.difference(MapSet.new(nodes), MapSet.new(state_nodes))
    |> Enum.each(fn
      n when n == node() -> nil
      n -> Node.monitor(n, true)
    end)
  end

  defp put_meta(state, key, value) do
    DeltaCrdt.mutate_async(registry_crdt_name(state.name), :add, [key, value])

    :ets.insert(state.registry_ets_table, {key, value})
  end

  defp invert_keys(keys) do
    Enum.reduce(keys, %{}, fn {key, {pid, _value}}, pids ->
      Map.update(pids, pid, [key], fn existing_keys -> [key | existing_keys] end)
    end)
  end

  defp sync_ets_table(ets_table, registry) do
    :ets.insert(ets_table, Map.to_list(registry))

    all_keys = :ets.match(ets_table, {:"$1", :_}) |> MapSet.new(fn [x] -> x end)
    new_keys = Map.keys(registry) |> MapSet.new()
    to_delete_keys = MapSet.difference(all_keys, new_keys)

    to_delete_keys |> Enum.each(fn key -> :ets.delete(ets_table, key) end)
  end
end
