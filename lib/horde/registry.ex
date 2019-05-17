defmodule Horde.Registry do
  @moduledoc """
  A distributed process registry.

  Horde.Registry implements a distributed Registry backed by an add-wins last-write-wins δ-CRDT (provided by `DeltaCrdt.AWLWWMap`). This CRDT is used for both tracking membership of the cluster and implementing the registry functionality itself. Local changes to the registry will automatically be synced to other nodes in the cluster.

  Because of the semantics of an AWLWWMap, the guarantees provided by Horde.Registry are more relaxed than those provided by the standard library Registry. Conflicts will be automatically silently resolved by the underlying AWLWWMap.

  Cluster membership is managed with `Horde.Cluster`. Joining a cluster can be done with `Horde.Cluster.set_members/2`. To take a node out of the cluster, call `Horde.Cluster.set_members/2` without that node in the list.

  Horde.Registry supports the common "via tuple", described in the [documentation](https://hexdocs.pm/elixir/GenServer.html#module-name-registration) for `GenServer`.

  ## Module-based Registry

  Horde supports module-based registries to enable dynamic runtime configuration.

  ```elixir
  defmodule MyRegistry do
    use Horde.Registry

    def init(options) do
      {:ok, Keyword.put(options, :members, get_members())}
    end

    defp get_members() do
      # ...
    end
  end
  ```

  Then you can use `MyRegistry.child_spec/1` and `MyRegistry.start_link/1` in the same way as you'd use `Horde.Registry.child_spec/1` and `Horde.Registry.start_link/1`.
  """

  @callback init(options :: Keyword.t()) :: {:ok, options :: Keyword.t()}

  defmacro __using__(_opts) do
    quote do
      @behaviour Horde.Registry

      def child_spec(options) do
        options = Keyword.put_new(options, :id, __MODULE__)

        %{
          id: Keyword.get(options, :id, __MODULE__),
          start: {__MODULE__, :start_link, [options]},
          type: :supervisor
        }
      end

      def start_link(options) do
        Horde.Registry.start_link(Keyword.put(options, :init_module, __MODULE__))
      end
    end
  end

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
    options = Keyword.put_new(options, :id, __MODULE__)

    %{
      id: Keyword.get(options, :id, __MODULE__),
      start: {__MODULE__, :start_link, [options]},
      type: :supervisor
    }
  end

  @doc "Starts the registry as a supervised process"
  def start_link(options) do
    root_name = Keyword.get(options, :name)

    case Keyword.get(options, :keys) do
      :unique -> nil
      _other -> raise ArgumentError, "Only `keys: :unique` is supported."
    end

    if is_nil(root_name) do
      raise "must specify :name in options, got: #{inspect(options)}"
    end

    options = Keyword.put(options, :root_name, root_name)

    options = Keyword.put_new(options, :members, [root_name])

    Supervisor.start_link(Horde.RegistrySupervisor, options, name: :"#{root_name}.Supervisor")
  end

  @spec stop(Supervisor.supervisor(), reason :: term(), timeout()) :: :ok
  def stop(supervisor, reason \\ :normal, timeout \\ 5000) do
    Supervisor.stop(supervisor, reason, timeout)
  end

  ### Public API

  @doc """
  Register a process under the given name

  When 2 clustered registries register the same name at exactly the
  same time, it will seem like name registration succeeds for both
  registries. The function returns `{:ok, pid}` for both of these
  calls.

  However, due to the eventual consistent nature of the CRDT, a
  conflict resolution will take place, and the CRDT will pick one of
  the two processes as the "winner" of the name. The losing process
  will be sent an exit signal (using `Process.exit/2`) with the
  following reason:

  `{:name_conflict, {name, value}, registry_name, winning_pid}`

  When two registries are joined using `Horde.Cluster.set_members/2`,
  this name conflict message can also occur.
  """
  @spec register(
          registry :: GenServer.server(),
          name :: Registry.key(),
          value :: Registry.value()
        ) :: {:ok, pid()} | {:error, :already_registered, pid()}
  def register(registry, name, value) when is_atom(registry) do
    case :ets.lookup(keys_ets_table(registry), name) do
      [] ->
        GenServer.call(registry, {:register, name, value, self()})

      [{^name, _member, {pid, _value}}] ->
        {:error, {:already_registered, pid}}
    end
  end

  @doc "unregister the process under the given name"
  @spec unregister(registry :: GenServer.server(), name :: GenServer.name()) :: :ok
  def unregister(registry, name) when is_atom(registry) do
    GenServer.call(registry, {:unregister, name, self()})
  end

  @doc false
  def whereis(search), do: lookup(search)

  @doc false
  def lookup({:via, _, {registry, name}}), do: lookup(registry, name)

  @doc "Finds the `{pid, value}` for the given `key` in `registry`"
  def lookup(registry, key) when is_atom(registry) do
    with [{^key, member, {pid, value}}] <- :ets.lookup(keys_ets_table(registry), key),
         true <- member_in_cluster?(registry, member),
         true <- process_alive?(pid) do
      [{pid, value}]
    else
      _ -> :undefined
    end
  end

  @spec meta(registry :: Registry.registry(), key :: Registry.meta_key()) ::
          {:ok, Registry.meta_value()} | :error
  @doc "Reads registry metadata given on `start_link/3`"
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
  def put_meta(registry, key, value) when is_atom(registry) do
    GenServer.call(registry, {:put_meta, key, value})
  end

  @spec count(registry :: Registry.registry()) :: non_neg_integer()
  @doc "Returns the number of keys in a registry. It runs in constant time."
  def count(registry) when is_atom(registry) do
    :ets.info(keys_ets_table(registry), :size)
  end

  @doc "See `Registry.match/4` for details."
  def match(registry, key, pattern, guards \\ [])
      when is_atom(registry) and is_list(guards) do
    underscore_guard = {:"=:=", {:element, 1, :"$_"}, {:const, key}}
    spec = [{{:_, :_, {:_, pattern}}, [underscore_guard | guards], [{:element, 3, :"$_"}]}]

    :ets.select(keys_ets_table(registry), spec)
  end

  def count_match(registry, key, pattern, guards \\ [])
      when is_atom(registry) and is_list(guards) do
    underscore_guard = {:"=:=", {:element, 1, :"$_"}, {:const, key}}
    spec = [{{:_, :_, {:_, pattern}}, [underscore_guard | guards], [true]}]

    :ets.select_count(keys_ets_table(registry), spec)
  end

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
  @doc "Returns registered keys for `pid`"
  def keys(registry, pid) when is_atom(registry) do
    case :ets.lookup(pids_ets_table(registry), pid) do
      [] -> []
      [{_pid, matches}] -> matches
    end
  end

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

  @doc """
  Get the process registry of the horde
  """
  @deprecated "Use `select/2` instead."
  def processes(registry) when is_atom(registry) do
    :ets.match(keys_ets_table(registry), :"$1") |> Map.new(fn [{k, _m, v}] -> {k, v} end)
  end

  @doc """
  Select key, pid, and values from the process registry of the horde
  """
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
  def register_name({registry, key}, pid), do: register_name({registry, key, nil}, pid)

  def register_name({registry, key, value}, pid) when is_atom(registry) do
    case GenServer.call(registry, {:register, key, value, pid}) do
      {:ok, _pid} -> :yes
      {:error, _} -> :no
    end
  end

  @doc false
  # @spec whereis_name({pid, term}) :: pid | :undefined
  def whereis_name({registry, name}) when is_atom(registry) do
    case lookup(registry, name) do
      :undefined -> :undefined
      [{pid, _val}] -> pid
    end
  end

  @doc false
  def unregister_name({registry, name}), do: unregister(registry, name)

  @doc false
  def send({registry, name}, msg) when is_atom(registry) do
    case lookup(registry, name) do
      :undefined -> :erlang.error(:badarg, [{registry, name}, msg])
      [{pid, _value}] -> Kernel.send(pid, msg)
    end
  end

  defp process_alive?(pid) when node(pid) == node(), do: Process.alive?(pid)

  defp process_alive?(pid) do
    n = node(pid)
    Node.list() |> Enum.member?(n) && :rpc.call(n, Process, :alive?, [pid])
  end

  defp member_in_cluster?(registry, member) do
    case :ets.lookup(members_ets_table(registry), member) do
      [] -> false
      _ -> true
    end
  end

  defp registry_ets_table(registry), do: registry
  defp pids_ets_table(registry), do: :"pids_#{registry}"
  defp keys_ets_table(registry), do: :"keys_#{registry}"
  defp members_ets_table(registry), do: :"members_#{registry}"
end
