defmodule Horde.RegistryImpl do
  @moduledoc false

  @update_processes_debounce 50
  @force_update_processes 1000

  defmodule State do
    @moduledoc false
    defstruct node_id: nil,
              name: nil,
              members_pid: nil,
              members: %{},
              processes_pid: nil,
              processes_updated_counter: 0,
              processes_updated_at: 0,
              ets_table: nil
  end

  @crdt DeltaCrdt.AWLWWMap

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

  def terminate(reason, state) do
    GenServer.cast(
      state.members_pid,
      {:operation, {:remove, [state.node_id]}}
    )
  end

  ### GenServer callbacks

  def init(opts) do
    node_id = generate_node_id()

    name = Keyword.get(opts, :name)
    members_pid = Process.whereis(members_crdt_name(name))
    processes_pid = Process.whereis(processes_crdt_name(name))

    unless is_atom(name) do
      raise ArgumentError, "expected :name to be given and to be an atom, got: #{inspect(name)}"
    end

    :ets.new(name, [:named_table, {:read_concurrency, true}])

    GenServer.cast(
      members_crdt_name(name),
      {:operation, {:add, [node_id, {members_pid, processes_pid}]}}
    )

    {:ok,
     %State{
       node_id: node_id,
       name: name,
       ets_table: name,
       members_pid: members_pid,
       processes_pid: processes_pid
     }}
  end

  def handle_cast(
        {:request_to_join_hordes, {_other_node_id, other_members_pid, reply_to}},
        state
      ) do
    send(state.members_pid, {:add_neighbours, [other_members_pid]})
    GenServer.reply(reply_to, true)
    {:noreply, state}
  end

  def handle_info({:processes_updated, reply_to}, state) do
    processes = DeltaCrdt.CausalCrdt.read(state.processes_pid, 30_000)

    :ets.insert(state.ets_table, Map.to_list(processes))

    all_keys = :ets.match(state.ets_table, {:"$1", :_}) |> MapSet.new(fn [x] -> x end)
    new_keys = Map.keys(processes) |> MapSet.new()
    to_delete_keys = MapSet.difference(all_keys, new_keys)

    to_delete_keys |> Enum.each(fn key -> :ets.delete(state.ets_table, key) end)

    GenServer.reply(reply_to, :ok)

    {:noreply, state}
  end

  def handle_info({:members_updated, reply_to}, state) do
    members = DeltaCrdt.CausalCrdt.read(state.members_pid, 30_000)
    members_pid = state.members_pid

    member_pids =
      MapSet.new(members, fn {_key, {members_pid, _processes_pid}} ->
        members_pid
      end)
      |> MapSet.delete(nil)

    state_member_pids =
      MapSet.new(state.members, fn {_key, {members_pid, _processes_pid}} ->
        members_pid
      end)
      |> MapSet.delete(nil)

    # if there are any new pids in `member_pids`
    if MapSet.difference(member_pids, state_member_pids) |> Enum.any?() do
      processes_pids =
        MapSet.new(members, fn {_node_id, {_mpid, pid}} -> pid end) |> MapSet.delete(nil)

      send(state.members_pid, {:add_neighbours, member_pids})
      send(state.processes_pid, {:add_neighbours, processes_pids})
    end

    GenServer.reply(reply_to, :ok)

    {:noreply, %{state | members: members}}
  end

  def handle_call({:join_hordes, other_horde}, from, state) do
    GenServer.cast(
      other_horde,
      {:request_to_join_hordes, {state.node_id, state.members_pid, from}}
    )

    {:noreply, state}
  end

  def handle_call(:get_ets_table, _from, %{ets_table: ets_table} = state),
    do: {:reply, ets_table, state}

  def handle_call({:register, name, pid}, _from, state) do
    GenServer.cast(
      state.processes_pid,
      {:operation, {:add, [name, {pid}]}}
    )

    :ets.insert(state.ets_table, {name, {pid}})

    {:reply, {:ok, pid}, state}
  end

  def handle_call({:unregister, name}, _from, state) do
    GenServer.cast(
      state.processes_pid,
      {:operation, {:remove, [name]}}
    )

    :ets.delete(state.ets_table, name)

    {:reply, :ok, state}
  end

  def handle_call(:members, _from, state) do
    {:reply, {:ok, state.members}, state}
  end

  defp generate_node_id(bytes \\ 16) do
    :base64.encode(:crypto.strong_rand_bytes(bytes))
  end

  defp members_crdt_name(name), do: :"#{name}.MembersCrdt"
  defp processes_crdt_name(name), do: :"#{name}.ProcessesCrdt"
end
