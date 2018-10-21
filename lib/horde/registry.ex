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

  def start_link(options) do
    root_name = Keyword.get(options, :name)

    case Keyword.get(options, :keys) do
      :unique -> nil
      other -> raise ArgumentError, "Only `keys: :unique` is supported."
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

  @doc false
  def whereis(search), do: lookup(search)

  @doc false
  def lookup({:via, _, {horde, name}}), do: lookup(horde, name)

  def lookup(horde, name) do
    with [{^name, {pid}}] <- :ets.lookup(get_ets_table(horde), name),
         true <- process_alive?(pid) do
      pid
    else
      _ -> :undefined
    end
  end

  @doc """
  Get the process registry of the horde
  """
  @deprecated "Use keys/2 instead"
  def processes(horde) do
    :ets.match(get_ets_table(horde), :"$1") |> Map.new(fn [{k, v}] -> {k, v} end)
  end

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

  defp process_alive?(pid) when node(pid) == node(self()), do: Process.alive?(pid)

  defp process_alive?(pid) do
    n = node(pid)
    Node.list() |> Enum.member?(n) && :rpc.call(n, Process, :alive?, [pid])
  end

  defp get_ets_table(tab) when is_atom(tab), do: tab
  defp get_ets_table(tab), do: GenServer.call(tab, :get_ets_table)
end
