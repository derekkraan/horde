defmodule Horde.Registry do
  @moduledoc """
  A distributed process registry.

  Horde.Registry implements a distributed Registry backed by a δ-CRDT (provided by `DeltaCrdt`). This CRDT is used for both tracking membership of the cluster and implementing the registry functionality itself. Local changes to the registry will automatically be synced to other nodes in the cluster.

  Cluster membership is managed with `Horde.Cluster`. Joining a cluster can be done with `Horde.Cluster.set_members/2`. To take a node out of the cluster, call `Horde.Cluster.set_members/2` without that node in the list. Alternatively, setting the `members` startup option to `:auto` will make Horde auto-manage cluster membership so that all (and only) visible nodes are members of the cluster.

  Horde.Registry supports the common "via tuple", described in the [documentation](https://hexdocs.pm/elixir/GenServer.html#module-name-registration) for `GenServer`.

  Horde.Registry is API-compatible with `Registry`, with the following exceptions:
  - Horde.Registry does not support `keys: :duplicate`.
  - Horde.Registry does not support partitions.
  - Horde.Registry sends an exit signal to a process when it has lost a naming conflict. See `Horde.Registry.register/3` for details.

  ## Module-based Registry

  Horde supports module-based registries to enable dynamic runtime configuration.

  ```elixir
  defmodule MyRegistry do
    use Horde.Registry

    def start_link(_) do
      Horde.Registry.start_link(__MODULE__, [keys: :unique], name: __MODULE__)
    end

    def init(init_arg) do
      [members: members()]
      |> Keyword.merge(init_arg)
      |> Horde.Registry.init()
    end

    defp members() do
      [Node.self() | Node.list()]
      |> Enum.map(fn node -> {__MODULE__, node} end)
    end
  end
  ```

  Then you can use `MyRegistry.child_spec/1` and `MyRegistry.start_link/1` in the same way as you'd use `Horde.Registry.child_spec/1` and `Horde.Registry.start_link/1`.
  """
  use Supervisor

  @type options :: [option()]
  @type option ::
          {:keys, :unique}
          | {:name, atom()}
          | {:delta_crdt_options, [DeltaCrdt.crdt_option()]}
          | {:members, [Horde.Cluster.member()] | :auto}

  @callback init(options :: Keyword.t()) :: {:ok, options()} | :ignore
  @callback child_spec(options :: options()) :: Supervisor.child_spec()

  defmacro __using__(options) do
    quote location: :keep, bind_quoted: [options: options] do
      @behaviour Horde.Registry
      if Module.get_attribute(__MODULE__, :doc) == nil do
        @doc """
        Returns a specification to start this module under a supervisor.
        See `Supervisor`.
        """
      end

      @impl true
      def child_spec(arg) do
        default = %{
          id: __MODULE__,
          start: {__MODULE__, :start_link, [arg]},
          type: :supervisor
        }

        Supervisor.child_spec(default, unquote(Macro.escape(options)))
      end

      defoverridable child_spec: 1
    end
  end

  @doc """
  See `start_link/2` for options.
  """
  def child_spec(options) when is_list(options) do
    id = Keyword.get(options, :name, Horde.Registry)

    %{
      id: id,
      start: {Horde.Registry, :start_link, [options]},
      type: :supervisor
    }
  end

  @doc """
  See `Registry.start_link/1`.

  Does not accept `[partitions: x]`, nor `[keys: :duplicate]` as options.
  """
  def start_link(options) when is_list(options) do
    keys = [
      :listeners,
      :meta,
      :keys,
      :distribution_strategy,
      :members,
      :delta_crdt_options
    ]

    {sup_options, start_options} = Keyword.split(options, keys)
    start_link(Supervisor.Default, init(sup_options), start_options)
  end

  def start_link(mod, init_arg, opts \\ []) do
    name = :"#{opts[:name]}.Supervisor"
    start_options = Keyword.put(opts, :name, name)
    Supervisor.start_link(__MODULE__, {mod, init_arg, opts[:name]}, start_options)
  end

  @doc """
  Works like `Registry.init/1`.
  """
  def init(options) when is_list(options) do
    unless keys = options[:keys] do
      raise ArgumentError, "expected :keys option to be given"
    end

    case Keyword.get(options, :keys) do
      :unique -> :ok
      _ -> raise ArgumentError, "Only `keys: :unique` is supported."
    end

    listeners = Keyword.get(options, :listeners, [])
    meta = Keyword.get(options, :meta, nil)
    members = Keyword.get(options, :members, [])
    delta_crdt_options = Keyword.get(options, :delta_crdt_options, [])

    distribution_strategy =
      Keyword.get(
        options,
        :distribution_strategy,
        Horde.UniformDistribution
      )

    flags = %{
      listeners: listeners,
      meta: meta,
      keys: keys,
      distribution_strategy: distribution_strategy,
      members: members,
      delta_crdt_options: delta_crdt_options(delta_crdt_options)
    }

    {:ok, flags}
  end

  def init({mod, init_arg, name}) do
    case mod.init(init_arg) do
      {:ok, flags} when is_map(flags) ->
        [
          {DeltaCrdt,
           [
             sync_interval: flags.delta_crdt_options.sync_interval,
             max_sync_size: flags.delta_crdt_options.max_sync_size,
             shutdown: flags.delta_crdt_options.shutdown,
             crdt: DeltaCrdt.AWLWWMap,
             on_diffs: {Horde.RegistryImpl, :on_diffs, [name]},
             name: crdt_name(name)
           ]},
          {Horde.RegistryImpl,
           [
             name: name,
             listeners: flags.listeners,
             meta: flags.meta,
             keys: flags.keys,
             members: members(flags.members, name)
           ]}
        ]
        |> maybe_add_node_manager(flags.members, name)
        |> Supervisor.init(strategy: :one_for_all)

      :ignore ->
        :ignore

      other ->
        {:stop, {:bad_return, {mod, :init, other}}}
    end
  end

  @spec stop(Supervisor.supervisor(), reason :: term(), timeout()) :: :ok
  def stop(supervisor, reason \\ :normal, timeout \\ 5000) do
    Supervisor.stop(supervisor, reason, timeout)
  end

  ### Public API

  @doc """
  Register a process under the given name. See `Registry.register/3`.

  When 2 clustered registries register the same name at exactly the
  same time, it will seem like name registration succeeds for both
  registries. The function returns `{:ok, pid}` for both of these
  calls.

  However, due to the eventually consistent nature of the CRDT,
  conflict resolution will take place, and the CRDT will pick one of
  the two processes as the "winner" of the name. The losing process
  will be sent an exit signal (using `Process.exit/2`) with the
  following reason:

  `{:name_conflict, {name, value}, registry_name, winning_pid}`

  When two registries are joined using `Horde.Cluster.set_members/2`,
  this name conflict message can also occur.

  When a cluster is recovering from a netsplit, this name conflict
  message can also occur.
  """
  @spec register(
          registry :: Registry.registry(),
          name :: Registry.key(),
          value :: Registry.value()
        ) :: {:ok, pid()} | {:error, {:already_registered, pid()}}
  def register(registry, name, value) when is_atom(registry) do
    case lookup(registry, name) do
      [] ->
        GenServer.call(registry, {:register, name, value, self()})

      [{pid, _value}] ->
        {:error, {:already_registered, pid}}
    end
  end

  @doc "See `Registry.unregister/2`."
  @spec unregister(registry :: Registry.registry(), name :: Registry.key()) :: :ok
  def unregister(registry, name) when is_atom(registry) do
    GenServer.call(registry, {:unregister, name, self()})
  end

  @doc "See `Registry.delete_meta/2`."
  @spec delete_meta(registry :: Registry.registry(), name :: Registry.key()) :: :ok
  def delete_meta(registry, name) when is_atom(registry) do
    GenServer.call(registry, {:delete_meta, name})
  end

  @doc false
  def whereis(search), do: lookup(search)

  @doc "See `Registry.lookup/2`."
  def lookup({:via, _, {registry, name}}), do: lookup(registry, name)

  def lookup(registry, key) when is_atom(registry) do
    with [{^key, member, {pid, value}}] <- :ets.lookup(keys_ets_table(registry), key),
         true <- member_in_cluster?(registry, member),
         true <- process_alive?(pid) do
      [{pid, value}]
    else
      _ -> []
    end
  end

  @spec meta(registry :: Registry.registry(), key :: Registry.meta_key()) ::
          {:ok, Registry.meta_value()} | :error
  @doc "See `Registry.meta/2`."
  def meta(registry, key) when is_atom(registry) do
    case :ets.lookup(registry_ets_table(registry), key) do
      [{^key, value}] -> {:ok, value}
      _ -> :error
    end
  end

  @spec put_meta(
          registry :: Registry.registry(),
          key :: Registry.meta_key(),
          value :: Registry.meta_value()
        ) :: :ok
  @doc "See `Registry.put_meta/3`."
  def put_meta(registry, key, value) when is_atom(registry) do
    GenServer.call(registry, {:put_meta, key, value})
  end

  @spec count(registry :: Registry.registry()) :: non_neg_integer()
  @doc "See `Registry.count/1`."
  def count(registry) when is_atom(registry) do
    :ets.info(keys_ets_table(registry), :size)
  end

  @doc "See `Registry.match/4`."
  def match(registry, key, pattern, guards \\ [])
      when is_atom(registry) and is_list(guards) do
    underscore_guard = {:"=:=", {:element, 1, :"$_"}, {:const, key}}
    spec = [{{:_, :_, {:_, pattern}}, [underscore_guard | guards], [{:element, 3, :"$_"}]}]

    :ets.select(keys_ets_table(registry), spec)
  end

  @doc "See `Registry.count_match/4`."
  def count_match(registry, key, pattern, guards \\ [])
      when is_atom(registry) and is_list(guards) do
    underscore_guard = {:"=:=", {:element, 1, :"$_"}, {:const, key}}
    spec = [{{:_, :_, {:_, pattern}}, [underscore_guard | guards], [true]}]

    :ets.select_count(keys_ets_table(registry), spec)
  end

  @doc "See `Registry.unregister_match/4`."
  def unregister_match(registry, key, pattern, guards \\ [])
      when is_atom(registry) and is_list(guards) do
    pid = self()
    underscore_guard = {:"=:=", {:element, 1, :"$_"}, {:const, key}}
    spec = [{{:_, :_, {pid, pattern}}, [underscore_guard | guards], [:"$_"]}]

    :ets.select(keys_ets_table(registry), spec)
    |> Enum.each(fn {key, _member, {pid, _val}} ->
      GenServer.call(registry, {:unregister, key, pid})
    end)

    :ok
  end

  @spec keys(registry :: Registry.registry(), pid()) :: [Registry.key()]
  @doc "See `Registry.keys/2`."
  def keys(registry, pid) when is_atom(registry) do
    case :ets.lookup(pids_ets_table(registry), pid) do
      [] -> []
      [{_pid, matches}] -> matches
    end
  end

  @doc "See `Registry.dispatch/4`."
  def dispatch(registry, key, mfa_or_fun, _opts \\ []) when is_atom(registry) do
    case :ets.lookup(keys_ets_table(registry), key) do
      [] ->
        :ok

      [{_key, _member, pid_value}] ->
        do_dispatch(mfa_or_fun, [pid_value])
        :ok
    end
  end

  defp do_dispatch({m, f, a}, entries), do: apply(m, f, [entries | a])
  defp do_dispatch(fun, entries), do: fun.(entries)

  @doc "See `Registry.update_value/3`."
  def update_value(registry, key, callback) when is_atom(registry) do
    case :ets.lookup(keys_ets_table(registry), key) do
      [{key, _member, {pid, value}}] when pid == self() ->
        new_value = callback.(value)
        :ok = GenServer.call(registry, {:update_value, key, pid, new_value})
        {new_value, value}

      _ ->
        :error
    end
  end

  @doc "See `Registry.select/2`."
  def select(registry, spec) when is_atom(registry) and is_list(spec) do
    spec =
      for part <- spec do
        case part do
          {{key, pid, value}, guards, select} ->
            {{key, :_, {pid, value}}, guards, select}

          _ ->
            raise ArgumentError,
                  "invalid match specification in Registry.select/2: #{inspect(spec)}"
        end
      end

    :ets.select(keys_ets_table(registry), spec)
  end

  ### Via callbacks

  @doc false
  # @spec register_name({pid, term}, pid) :: :yes | :no
  def register_name({registry, key}, pid), do: register_name(registry, key, nil, pid)
  def register_name({registry, key, value}, pid), do: register_name(registry, key, value, pid)

  defp register_name(registry, key, value, pid) when is_atom(registry) do
    case GenServer.call(registry, {:register, key, value, pid}) do
      {:ok, _pid} -> :yes
      {:error, _} -> :no
    end
  end

  @doc false
  # @spec whereis_name({pid, term}) :: pid | :undefined
  def whereis_name({registry, key}), do: whereis_name(registry, key)
  def whereis_name({registry, key, _value}), do: whereis_name(registry, key)

  defp whereis_name(registry, name) when is_atom(registry) do
    case lookup(registry, name) do
      [] -> :undefined
      [{pid, _val}] -> pid
    end
  end

  @doc false
  def unregister_name({registry, name}), do: unregister(registry, name)

  @doc false
  def send({registry, name}, msg) when is_atom(registry) do
    case lookup(registry, name) do
      [] -> :erlang.error(:badarg, [{registry, name}, msg])
      [{pid, _value}] -> Kernel.send(pid, msg)
    end
  end

  defp maybe_add_node_manager(children, :auto, name),
    do: children ++ [{Horde.NodeListener, name}]

  defp maybe_add_node_manager(children, _, _), do: children

  defp process_alive?(pid) when node(pid) == node(), do: Process.alive?(pid)

  defp process_alive?(pid) do
    n = node(pid)

    Node.list() |> Enum.member?(n) &&
      :rpc.call(n, Process, :alive?, [pid])
  end

  defp member_in_cluster?(registry, member) do
    case :ets.lookup(members_ets_table(registry), member) do
      [] -> false
      _ -> true
    end
  end

  defp delta_crdt_options(options) do
    %{
      sync_interval: Keyword.get(options, :sync_interval, 300),
      max_sync_size: Keyword.get(options, :max_sync_size, :infinite),
      shutdown: Keyword.get(options, :shutdown, 30_000)
    }
  end

  defp members(:auto, _name), do: :auto

  defp members(options, name) do
    if name in options do
      options
    else
      [name | options]
    end
  end

  defp crdt_name(name), do: :"#{name}.Crdt"

  defp registry_ets_table(registry), do: registry
  defp pids_ets_table(registry), do: :"pids_#{registry}"
  defp keys_ets_table(registry), do: :"keys_#{registry}"
  defp members_ets_table(registry), do: :"members_#{registry}"
end
