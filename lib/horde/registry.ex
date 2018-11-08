defmodule Horde.Registry do
  @moduledoc """
  A distributed process registry.

  Horde.Registry implements a distributed Registry backed by an add-wins last-write-wins δ-CRDT (provided by `DeltaCrdt.AWLWWMap`). This CRDT is used for both tracking membership of the cluster and implementing the registry functionality itself. Local changes to the registry will automatically be synced to other nodes in the cluster.

  Because of the semantics of an AWLWWMap, the guarantees provided by Horde.Registry are more relaxed than those provided by the standard library Registry. Conflicts will be automatically silently resolved by the underlying AWLWWMap.

  Cluster membership is managed with `Horde.Cluster`. Joining a cluster can be done with `Horde.Cluster.join_hordes/2` and leaving the cluster happens automatically when you stop the registry with `Horde.Registry.stop/3`.

  Horde.Registry supports the common "via tuple", described in the [documentation](https://hexdocs.pm/elixir/GenServer.html#module-name-registration) for `GenServer`.
  """

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

    Supervisor.start_link(Horde.RegistrySupervisor, options, name: :"#{root_name}.Supervisor")
  end

  @spec stop(Supervisor.supervisor(), reason :: term(), timeout()) :: :ok
  def stop(supervisor, reason \\ :normal, timeout \\ 5000) do
    Supervisor.stop(supervisor, reason, timeout)
  end

  ### Public API

  @doc "Register a process under the given name"
  @spec register(horde :: GenServer.server(), name :: Registry.key(), value :: Registry.value()) ::
          {:ok, pid()} | {:error, :already_registered, pid()}
  def register(horde, name, value) do
    GenServer.call(horde, {:register, name, value, self()})
  end

  @doc "unregister the process under the given name"
  @spec unregister(horde :: GenServer.server(), name :: GenServer.name()) :: :ok
  def unregister(horde, name) do
    GenServer.call(horde, {:unregister, name, self()})
  end

  @doc false
  def whereis(search), do: lookup(search)

  @doc false
  def lookup({:via, _, {registry, name}}), do: lookup(registry, name)

  @doc "Finds the `{pid, value}` for the given `key` in `registry`"
  def lookup(registry, key) do
    with [{^key, {pid, value}}] <- :ets.lookup(get_keys_ets_table(registry), key),
         true <- process_alive?(pid) do
      [{pid, value}]
    else
      _ -> :undefined
    end
  end

  @spec meta(registry :: Registry.registry(), key :: Registry.meta_key()) ::
          {:ok, Registry.meta_value()} | :error
  @doc "Reads registry metadata given on `start_link/3`"
  def meta(registry, key) do
    case :ets.lookup(get_registry_ets_table(registry), key) do
      [{^key, value}] -> {:ok, value}
      _ -> :error
    end
  end

  @spec put_meta(
          registry :: Registry.registry(),
          key :: Registry.meta_key(),
          value :: Registry.meta_value()
        ) :: :ok
  def put_meta(registry, key, value) do
    GenServer.call(registry, {:put_meta, key, value})
  end

  @spec count(registry :: Registry.registry()) :: non_neg_integer()
  @doc "Returns the number of keys in a registry. It runs in constant time."
  def count(registry) do
    :ets.info(get_keys_ets_table(registry), :size)
  end

  def count_match(registry, key, pattern, guards \\ [])
      when is_atom(registry) and is_list(guards) do
    guards = [{:"=:=", {:element, 1, :"$_"}, {:const, key}} | guards]
    spec = [{{:_, {:_, pattern}}, guards, [true]}]
    :ets.select_count(get_keys_ets_table(registry), spec)
  end

  @spec keys(registry :: Registry.registry(), pid()) :: [Registry.key()]
  @doc "Returns registered keys for `pid`"
  def keys(registry, pid) do
    case :ets.lookup(get_pids_ets_table(registry), pid) do
      [] -> []
      [{_pid, matches}] -> matches
    end
  end

  def match(registry, key, pattern, guards \\ [])
      when is_atom(registry) and is_list(guards) do
    guards = [{:"=:=", {:element, 1, :"$_"}, {:const, key}} | guards]
    spec = [{{:_, {:_, pattern}}, guards, [{:element, 2, :"$_"}]}]
    :ets.select(get_keys_ets_table(registry), spec)
  end

  def dispatch(registry, key, mfa_or_fun, _opts \\ []) do
    case :ets.lookup(get_keys_ets_table(registry), key) do
      [] ->
        :ok

      [{_key, pid_value}] ->
        do_dispatch(mfa_or_fun, [pid_value])
        :ok
    end
  end

  defp do_dispatch({m, f, a}, entries), do: apply(m, f, [entries | a])
  defp do_dispatch(fun, entries), do: fun.(entries)

  def unregister_match(registry, key, pattern, guards \\ []) when is_list(guards) do
    self = self()
    underscore_guard = {:"=:=", {:element, 1, :"$_"}, {:const, key}}
    delete_spec = [{{:_, {self, pattern}}, [underscore_guard | guards], [:"$_"]}]

    :ets.select(get_keys_ets_table(registry), delete_spec)
    |> Enum.each(fn {key, {pid, _val}} ->
      GenServer.call(registry, {:unregister, key, pid})
    end)

    :ok
  end

  def update_value(registry, key, callback) do
    case :ets.lookup(get_keys_ets_table(registry), key) do
      [] ->
        :error

      [{key, {pid, value}}] ->
        new_value = callback.(value)
        :ok = GenServer.call(registry, {:update_value, key, pid, new_value})
        {new_value, value}
    end
  end

  @doc """
  Get the process registry of the horde
  """
  @deprecated "Use keys/2 instead"
  def processes(horde) do
    :ets.match(get_keys_ets_table(horde), :"$1") |> Map.new(fn [{k, v}] -> {k, v} end)
  end

  ### Via callbacks

  @doc false
  # @spec register_name({pid, term}, pid) :: :yes | :no
  def register_name({registry, key}, pid), do: register_name({registry, key, nil}, pid)

  def register_name({registry, key, value}, pid) do
    case GenServer.call(registry, {:register, key, value, pid}) do
      {:ok, _pid} -> :yes
      {:error, _} -> :no
    end
  end

  @doc false
  # @spec whereis_name({pid, term}) :: pid | :undefined
  def whereis_name({horde, name}) do
    case lookup(horde, name) do
      :undefined -> :undefined
      [{pid, _val}] -> pid
    end
  end

  @doc false
  def unregister_name({horde, name}), do: unregister(horde, name)

  @doc false
  def send({horde, name}, msg) do
    case lookup(horde, name) do
      :undefined -> :erlang.error(:badarg, [{horde, name}, msg])
      [{pid, _value}] -> Kernel.send(pid, msg)
    end
  end

  defp process_alive?(pid) when node(pid) == node(self()), do: Process.alive?(pid)

  defp process_alive?(pid) do
    n = node(pid)
    Node.list() |> Enum.member?(n) && :rpc.call(n, Process, :alive?, [pid])
  end

  defp get_registry_ets_table(tab), do: GenServer.call(tab, :get_registry_ets_table)
  defp get_pids_ets_table(tab), do: GenServer.call(tab, :get_pids_ets_table)
  defp get_keys_ets_table(tab), do: GenServer.call(tab, :get_keys_ets_table)
end
