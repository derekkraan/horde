defmodule Horde.RegistryImpl do
  @moduledoc false

  require Logger

  defmodule State do
    @moduledoc false
    defstruct node_id: nil,
              members: %{},
              members_pid: nil,
              registry_pid: nil,
              pids_pid: nil,
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
    GenServer.cast(
      state.members_pid,
      {:operation, {:remove, [state.node_id]}}
    )
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
    pids_pid = Process.whereis(pids_crdt_name(name))
    keys_pid = Process.whereis(keys_crdt_name(name))

    unless is_atom(name) do
      raise ArgumentError, "expected :name to be given and to be an atom, got: #{inspect(name)}"
    end

    :ets.new(name, [:named_table, {:read_concurrency, true}])
    :ets.new(pids_name, [:named_table, {:read_concurrency, true}])
    :ets.new(keys_name, [:named_table, {:read_concurrency, true}])

    GenServer.cast(
      members_crdt_name(name),
      {:operation, {:add, [node_id, {members_pid, registry_pid, pids_pid, keys_pid}]}}
    )

    {:ok,
     %State{
       node_id: node_id,
       members_pid: members_pid,
       registry_pid: registry_pid,
       pids_pid: pids_pid,
       keys_pid: keys_pid,
       registry_ets_table: name,
       pids_ets_table: pids_name,
       keys_ets_table: keys_name
     }}
  end

  def handle_cast(
        {:request_to_join_hordes, {:registry, _other_node_id, other_members_pid, reply_to}},
        state
      ) do
    send(state.members_pid, {:add_neighbours, [other_members_pid]})
    GenServer.reply(reply_to, true)
    {:noreply, state}
  end

  def handle_info({:pids_updated, reply_to}, state) do
    processes = DeltaCrdt.CausalCrdt.read(state.pids_pid, 30_000)

    :ets.insert(state.keys_ets_table, Map.to_list(processes))

    all_keys = :ets.match(state.keys_ets_table, {:"$1", :_}) |> MapSet.new(fn [x] -> x end)
    new_keys = Map.keys(processes) |> MapSet.new()
    to_delete_keys = MapSet.difference(all_keys, new_keys)

    to_delete_keys |> Enum.each(fn key -> :ets.delete(state.keys_ets_table, key) end)

    GenServer.reply(reply_to, :ok)

    {:noreply, state}
  end

  def handle_info({:members_updated, reply_to}, state) do
    members = DeltaCrdt.CausalCrdt.read(state.members_pid, 30_000)

    member_pids =
      MapSet.new(members, fn {_key, {members_pid, _registry_pid, _pids_pid, _keys_pid}} ->
        members_pid
      end)
      |> MapSet.delete(nil)

    state_member_pids =
      MapSet.new(state.members, fn {_key, {members_pid, _registry_pid, _pids_pid, _keys_pid}} ->
        members_pid
      end)
      |> MapSet.delete(nil)

    # if there are any new pids in `member_pids`
    if MapSet.difference(member_pids, state_member_pids) |> Enum.any?() do
      registry_pids =
        MapSet.new(members, fn {_node_id, {_mpid, reg_pid, _pids_pid, _keys_pid}} -> reg_pid end)
        |> MapSet.delete(nil)

      pids_pids =
        MapSet.new(members, fn {_node_id, {_mpid, _reg_pid, pids_pid, _keys_pid}} -> pids_pid end)
        |> MapSet.delete(nil)

      keys_pids =
        MapSet.new(members, fn {_node_id, {_mpid, _reg_pid, _pids_pid, keys_pid}} -> keys_pid end)
        |> MapSet.delete(nil)

      send(state.members_pid, {:add_neighbours, member_pids})
      send(state.registry_pid, {:add_neighbours, registry_pids})
      send(state.pids_pid, {:add_neighbours, pids_pids})
      send(state.keys_pid, {:add_neighbours, keys_pids})
    end

    GenServer.reply(reply_to, :ok)

    {:noreply, %{state | members: members}}
  end

  def handle_call({:join_hordes, other_horde}, from, state) do
    GenServer.cast(
      other_horde,
      {:request_to_join_hordes, {:registry, state.node_id, state.members_pid, from}}
    )

    {:noreply, state}
  end

  def handle_call(:get_keys_ets_table, _from, %{keys_ets_table: t} = state),
    do: {:reply, t, state}

  def handle_call({:register, name, pid}, _from, state) do
    GenServer.cast(
      state.pids_pid,
      {:operation, {:add, [name, {pid}]}}
    )

    :ets.insert(state.keys_ets_table, {name, {pid}})

    {:reply, {:ok, pid}, state}
  end

  def handle_call({:unregister, name}, _from, state) do
    GenServer.cast(
      state.pids_pid,
      {:operation, {:remove, [name]}}
    )

    :ets.delete(state.keys_ets_table, name)

    {:reply, :ok, state}
  end

  def handle_call(:members, _from, state) do
    {:reply, {:ok, state.members}, state}
  end

  defp generate_node_id(bytes \\ 16) do
    :base64.encode(:crypto.strong_rand_bytes(bytes))
  end

  defp members_crdt_name(name), do: :"#{name}.MembersCrdt"
  defp registry_crdt_name(name), do: :"#{name}.RegistryCrdt"
  defp pids_crdt_name(name), do: :"#{name}.PidsCrdt"
  defp keys_crdt_name(name), do: :"#{name}.KeysCrdt"
end
