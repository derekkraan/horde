defmodule Horde.RegistryImpl do
  @moduledoc false

  require Logger

  defmodule State do
    @moduledoc false
    defstruct node_id: nil,
              nodes: MapSet.new(),
              members_pid: nil,
              registry_pid: nil,
              keys_pid: nil,
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
    DeltaCrdt.mutate_async(state.members_pid, :remove, [state.node_id])
  end

  ### GenServer callbacks

  def init(opts) do
    Process.flag(:trap_exit, true)

    node_id = generate_node_id()

    name = Keyword.get(opts, :name)
    pids_name = :"pids_#{name}"
    keys_name = :"keys_#{name}"

    Logger.info("Starting #{inspect(__MODULE__)} with name #{inspect(name)}")

    members_pid = Process.whereis(members_crdt_name(name))
    registry_pid = Process.whereis(registry_crdt_name(name))
    keys_pid = Process.whereis(keys_crdt_name(name))

    unless is_atom(name) do
      raise ArgumentError, "expected :name to be given and to be an atom, got: #{inspect(name)}"
    end

    :ets.new(name, [:named_table, {:read_concurrency, true}])
    :ets.new(pids_name, [:named_table, {:read_concurrency, true}])
    :ets.new(keys_name, [:named_table, {:read_concurrency, true}])

    state = %State{
      node_id: node_id,
      members_pid: members_pid,
      registry_pid: registry_pid,
      keys_pid: keys_pid,
      registry_ets_table: name,
      pids_ets_table: pids_name,
      keys_ets_table: keys_name
    }

    mark_alive(state)

    case Keyword.get(opts, :meta) do
      nil ->
        nil

      meta ->
        Enum.each(meta, fn {key, value} -> put_meta(state, key, value) end)
    end

    {:ok, state}
  end

  def handle_cast(
        {:request_to_join_hordes, {:registry, _other_node_id, other_members_pid, reply_to}},
        state
      ) do
    send(state.members_pid, {:add_neighbours, [other_members_pid]})
    GenServer.reply(reply_to, :ok)

    mark_alive(state)
    {:noreply, state}
  end

  defp mark_alive(state) do
    DeltaCrdt.mutate_async(
      state.members_pid,
      :add,
      [
        state.node_id,
        %{
          own_pid: self(),
          members_pid: state.members_pid,
          registry_pid: state.registry_pid,
          keys_pid: state.keys_pid
        }
      ]
    )
  end

  def handle_info({:registry_updated, reply_to}, state) do
    registry = DeltaCrdt.read(state.registry_pid, 30_000)
    sync_ets_table(state.registry_ets_table, registry)
    GenServer.reply(reply_to, :ok)
    {:noreply, state}
  end

  def handle_info({:keys_updated, reply_to}, state) do
    keys = DeltaCrdt.read(state.keys_pid, 30_000)
    link_own_pids(keys)
    sync_ets_table(state.pids_ets_table, invert_keys(keys))
    sync_ets_table(state.keys_ets_table, keys)
    GenServer.reply(reply_to, :ok)
    {:noreply, state}
  end

  def handle_info({:members_updated, reply_to}, state) do
    members = DeltaCrdt.read(state.members_pid, 30_000)

    member_pids = Enum.map(members, fn {_key, %{members_pid: members_pid}} -> members_pid end)
    registry_pids = Enum.map(members, fn {_node_id, %{registry_pid: reg_pid}} -> reg_pid end)
    keys_pids = Enum.map(members, fn {_node_id, %{keys_pid: keys_pid}} -> keys_pid end)

    nodes =
      Enum.map(member_pids, fn pid -> node(pid) end)
      |> Enum.uniq()

    monitor_new_nodes(nodes, state)

    send(state.members_pid, {:add_neighbours, member_pids})
    send(state.registry_pid, {:add_neighbours, registry_pids})
    send(state.keys_pid, {:add_neighbours, keys_pids})

    GenServer.reply(reply_to, :ok)

    {:noreply, Map.put(state, :nodes, nodes)}
  end

  def handle_info({:EXIT, pid, _reason}, state) do
    case :ets.take(state.pids_ets_table, pid) do
      [{_pid, keys}] ->
        Enum.each(keys, fn key ->
          DeltaCrdt.mutate_async(state.keys_pid, :remove, [key])
          :ets.match_delete(state.keys_ets_table, {key, {pid, :_}})
        end)

      _ ->
        nil
    end

    {:noreply, state}
  end

  def handle_info({:nodedown, n}, state) do
    Enum.each(DeltaCrdt.read(state.keys_pid, 30_000), fn
      {key, {pid, value}} when node(pid) == n ->
        DeltaCrdt.mutate_async(state.keys_pid, :remove, [key])
        :ets.match_delete(state.keys_ets_table, {key, {pid, :_}})

      {key, {pid, value}} when node(pid) == node() ->
        DeltaCrdt.mutate_async(state.keys_pid, :add, [key, {pid, value}])
    end)

    new_nodes =
      Enum.filter(state.nodes, fn
        ^n -> false
        _ -> true
      end)

    {:noreply, Map.put(state, :nodes, new_nodes)}
  end

  def handle_call({:join_hordes, other_horde}, from, state) do
    GenServer.cast(
      other_horde,
      {:request_to_join_hordes, {:registry, state.node_id, state.members_pid, from}}
    )

    {:noreply, state}
  end

  def handle_call(:get_registry_ets_table, _from, %{registry_ets_table: t} = state),
    do: {:reply, t, state}

  def handle_call(:get_pids_ets_table, _from, %{pids_ets_table: t} = state),
    do: {:reply, t, state}

  def handle_call(:get_keys_ets_table, _from, %{keys_ets_table: t} = state),
    do: {:reply, t, state}

  def handle_call({:register, key, value, pid}, _from, state) do
    Process.link(pid)

    DeltaCrdt.mutate_async(state.keys_pid, :add, [key, {pid, value}])

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
    DeltaCrdt.mutate_async(state.keys_pid, :add, [key, {pid, value}])

    :ets.insert(state.keys_ets_table, {key, {pid, value}})

    {:reply, :ok, state}
  end

  def handle_call({:unregister, key, pid}, _from, state) do
    DeltaCrdt.mutate_async(state.keys_pid, :remove, [key])

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
    {:reply, {:ok, DeltaCrdt.read(state.members_pid, 30_000)}, state}
  end

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
    DeltaCrdt.mutate_async(state.registry_pid, :add, [key, value])

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

  defp generate_node_id(bytes \\ 16) do
    :base64.encode(:crypto.strong_rand_bytes(bytes))
  end

  defp members_crdt_name(name), do: :"#{name}.MembersCrdt"
  defp registry_crdt_name(name), do: :"#{name}.RegistryCrdt"
  defp keys_crdt_name(name), do: :"#{name}.KeysCrdt"
end
