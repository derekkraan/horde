defmodule Horde.Registry do
  @moduledoc """
  A distributed process registry.

  Horde.Registry implements a distributed Registry backed by an add-wins last-write-wins δ-CRDT (provided by `DeltaCrdt.AWLWWMap`). This CRDT is used for both tracking membership of the cluster and implementing the registry functionality itself. Local changes to the registry will automatically be synced to other nodes in the cluster.

  Because of the semantics of an AWLWWMap, the guarantees provided by Horde.Registry are more relaxed than those provided by the standard library Registry. Conflicts will be automatically silently resolved by the underlying AWLWWMap.

  Cluster membership is managed with `Horde.Cluster`. Joining and leaving a cluster can be done with `Horde.Cluster.join_hordes/2` and `Horde.Cluster.leave_hordes/1`.

  Horde.Registry supports the common "via tuple", described in the [documentation](https://hexdocs.pm/elixir/GenServer.html#module-name-registration) for `GenServer`.
  """
  import Kernel, except: [send: 2]

  @update_processes_debounce 50
  @force_update_processes 1000

  defmodule State do
    @moduledoc false
    defstruct node_id: nil,
              members_pid: nil,
              members: %{},
              processes_pid: nil,
              processes_updated_counter: 0,
              processes_updated_at: 0,
              ets_table: nil
  end

  @crdt DeltaCrdt.AWLWWMap

  @doc """
  Child spec to enable easy inclusion into a supervisor.

  Example:
  ```elixir
  supervise([
    Horde.Registry
  ])
  ```

  Example:
  ```elixir
  supervise([
    {Horde.Registry, [name: MyApp.GlobalRegistry]}
  ])
  ```
  """
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

  @doc "register a process under the given name"
  @spec register(horde :: GenServer.server(), name :: atom(), pid :: pid()) :: {:ok, pid()}
  def register(horde, name, pid \\ self())

  def register(horde, name, pid) do
    GenServer.call(horde, {:register, name, pid})
  end

  @doc "unregister the process under the given name"
  @spec unregister(horde :: GenServer.server(), name :: GenServer.name()) :: :ok
  def unregister(horde, name) do
    GenServer.call(horde, {:unregister, name})
  end

  def whereis(search), do: lookup(search)
  def lookup({:via, _, {horde, name}}), do: lookup(horde, name)

  def lookup(horde, name) do
    with [{^name, {pid}}] <- :ets.lookup(get_ets_table(horde), name),
         true <- process_alive?(pid) do
      pid
    else
      _ -> :undefined
    end
  end

  defp process_alive?(pid) when node(pid) == node(self()), do: Process.alive?(pid)

  defp process_alive?(pid) do
    :rpc.call(node(pid), Process, :alive?, [pid])
  end

  defp get_ets_table(tab) when is_atom(tab), do: tab
  defp get_ets_table(tab), do: GenServer.call(tab, :get_ets_table)

  ### Via callbacks

  @doc false
  # @spec register_name({pid, term}, pid) :: :yes | :no
  def register_name({horde, name}, pid) do
    case GenServer.call(horde, {:register, name, pid}) do
      {:ok, _pid} -> :yes
      _ -> :no
    end
  end

  @doc false
  # @spec whereis_name({pid, term}) :: pid | :undefined
  def whereis_name({horde, name}) do
    lookup(horde, name)
  end

  @doc false
  def unregister_name({horde, name}), do: unregister(horde, name)

  @doc false
  def send({horde, name}, msg) do
    case lookup(horde, name) do
      :undefined -> :erlang.error(:badarg, [{horde, name}, msg])
      pid -> Kernel.send(pid, msg)
    end
  end

  @doc """
  Get the process regsitry of the horde
  """
  def processes(horde) do
    :ets.match(get_ets_table(horde), :"$1") |> Map.new(fn [{k, v}] -> {k, v} end)
  end

  ### GenServer callbacks

  def init(opts) do
    node_id = generate_node_id()
    {:ok, members_pid} = @crdt.start_link({self(), :members_updated})

    {:ok, processes_pid} = @crdt.start_link({self(), :processes_updated})

    name = Keyword.get(opts, :name)

    unless is_atom(name) do
      raise ArgumentError, "expected :name to be given and to be an atom, got: #{inspect(name)}"
    end

    :ets.new(name, [:named_table, {:read_concurrency, true}])

    GenServer.cast(
      members_pid,
      {:operation, {@crdt, :add, [node_id, {members_pid, processes_pid}]}}
    )

    {:ok,
     %State{
       node_id: node_id,
       members_pid: members_pid,
       processes_pid: processes_pid,
       ets_table: name
     }}
  end

  def handle_cast(
        {:request_to_join_hordes, {_other_node_id, other_members_pid, reply_to}},
        state
      ) do
    Kernel.send(state.members_pid, {:add_neighbour, other_members_pid})
    Kernel.send(state.members_pid, :ship_interval_or_state_to_all)
    GenServer.reply(reply_to, true)
    {:noreply, state}
  end

  def handle_cast(:leave_hordes, state) do
    GenServer.cast(
      state.members_pid,
      {:operation, {@crdt, :remove, [state.node_id]}}
    )

    Kernel.send(state.members_pid, :ship_interval_or_state_to_all)
    {:noreply, state}
  end

  def handle_info(:processes_updated, state) do
    new_state = %{state | processes_updated_counter: state.processes_updated_counter + 1}

    Process.send_after(
      self(),
      {:update_processes, new_state.processes_updated_counter},
      @update_processes_debounce
    )

    {:noreply, new_state}
  end

  def handle_info(
        {:update_processes, c},
        %{processes_updated_at: d, processes_updated_counter: new_c} = state
      )
      when d - c > @force_update_processes do
    handle_info({:update_processes, new_c}, state)
  end

  def handle_info({:update_processes, c}, %{processes_updated_counter: c} = state) do
    processes = GenServer.call(state.processes_pid, {:read, @crdt})

    :ets.insert(state.ets_table, Map.to_list(processes))

    all_keys = :ets.match(state.ets_table, {:"$1", :_}) |> MapSet.new(fn [x] -> x end)
    new_keys = Map.keys(processes) |> MapSet.new()
    to_delete_keys = MapSet.difference(all_keys, new_keys)

    to_delete_keys |> Enum.each(fn key -> :ets.delete(state.ets_table, key) end)

    {:noreply, %{state | processes_updated_at: c}}
  end

  def handle_info({:update_processes, _c}, state), do: {:noreply, state}

  def handle_info(:members_updated, state) do
    members = GenServer.call(state.members_pid, {:read, @crdt})

    member_pids =
      MapSet.new(members, fn {_key, {members_pid, _processes_pid}} -> members_pid end)
      |> MapSet.delete(nil)

    state_member_pids =
      MapSet.new(state.members, fn {_key, {members_pid, _processes_pid}} -> members_pid end)
      |> MapSet.delete(nil)

    # if there are any new pids in `member_pids`
    if MapSet.difference(member_pids, state_member_pids) |> Enum.any?() do
      processes_pids =
        MapSet.new(members, fn {_node_id, {_mpid, pid}} -> pid end) |> MapSet.delete(nil)

      Kernel.send(state.members_pid, {:add_neighbours, member_pids})
      Kernel.send(state.processes_pid, {:add_neighbours, processes_pids})
      Kernel.send(state.members_pid, :ship_interval_or_state_to_all)
      Kernel.send(state.processes_pid, :ship_interval_or_state_to_all)
    end

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
      {:operation, {@crdt, :add, [name, {pid}]}}
    )

    :ets.insert(state.ets_table, {name, {pid}})

    {:reply, {:ok, pid}, state}
  end

  def handle_call({:unregister, name}, _from, state) do
    GenServer.cast(
      state.processes_pid,
      {:operation, {@crdt, :remove, [name]}}
    )

    :ets.delete(state.ets_table, name)

    {:reply, :ok, state}
  end

  def handle_call(:members, _from, state) do
    {:reply, {:ok, state.members}, state}
  end

  defp generate_node_id(bits \\ 128) do
    <<num::bits>> =
      Enum.reduce(0..Integer.floor_div(bits, 8), <<>>, fn _x, bin ->
        <<Enum.random(0..255)>> <> bin
      end)

    num
  end
end
