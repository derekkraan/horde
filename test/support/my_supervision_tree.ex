defmodule MySupervisionTree do
  use Supervisor

  def start_link([cluster: _, distribution: _, sync_interval: _] = args) do
    Supervisor.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(args) do
    children = [
      {MyRegistry, args},
      {MySupervisor, args},
      {MyNodeListener, args}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end

defmodule MyCluster do
  def set_members(cluster) do
    nodes = nodes(cluster)
    set_members(nodes, MyRegistry)
    set_members(nodes, MySupervisor)
  end

  def set_members(nodes, name) do
    members = members(nodes, name)
    :ok = Horde.Cluster.set_members(name, members)
  end

  def nodes(cluster) do
    [Node.self() | Node.list()]
    |> Enum.filter(fn node ->
      String.contains?("#{node}", cluster)
    end)
  end

  def members(nodes, name) when is_list(nodes) do
    Enum.map(nodes, fn node -> {name, node} end)
  end

  def members(cluster, name) when is_binary(cluster) do
    cluster
    |> nodes()
    |> members(name)
  end

  def start_server(node, name) do
    :rpc.call(node, MyCluster, :start_server, [name])
  end

  def start_server(name) do
    Horde.DynamicSupervisor.start_child(MySupervisor, {MyServer, name})
  end

  def whereis_server(name) do
    MyServer.whereis(name)
  end

  def whereis_server(node, name) do
    :rpc.call(node, MyCluster, :whereis_server, [name])
  end
end

defmodule MyRegistry do
  use Horde.Registry

  def start_link(args) do
    args =
      Keyword.merge(args,
        keys: :unique,
        delta_crdt_options: [
          sync_interval: args[:sync_interval]
        ]
      )

    Horde.Registry.start_link(__MODULE__, args, name: __MODULE__)
  end

  def init(args) do
    members = MyCluster.members(args[:cluster], __MODULE__)
    args = Keyword.merge(args, members: members)
    Horde.Registry.init(args)
  end

  def via_tuple(spec) do
    {:via, Horde.Registry, {__MODULE__, spec}}
  end

  def whereis(spec) do
    case Horde.Registry.lookup(spec) do
      [{pid, _data}] ->
        pid

      [] ->
        :not_found
    end
  end

  def pid() do
    Process.whereis(__MODULE__)
  end

  def alive?(node) do
    :rpc.call(node, MyRegistry, :alive?, [])
  end

  def alive?() do
    case pid() do
      pid when is_pid(pid) ->
        Process.alive?(pid)

      nil ->
        false
    end
  end
end

defmodule MySupervisor do
  use Horde.DynamicSupervisor

  def start_link(args) do
    args =
      Keyword.merge(args,
        restart: 5000,
        strategy: :one_for_one,
        delta_crdt_options: [
          sync_interval: args[:sync_interval]
        ],
        distribution_strategy: args[:distribution]
      )

    Horde.DynamicSupervisor.start_link(__MODULE__, args, name: __MODULE__)
  end

  def init(args) do
    members = MyCluster.members(args[:cluster], __MODULE__)
    args = Keyword.merge(args, members: members)
    Horde.DynamicSupervisor.init(args)
  end

  def pid() do
    Process.whereis(__MODULE__)
  end

  def alive?(node) do
    :rpc.call(node, MySupervisor, :alive?, [])
  end

  def alive?() do
    case pid() do
      pid when is_pid(pid) ->
        Process.alive?(pid)

      nil ->
        false
    end
  end
end

defmodule MyNodeListener do
  use GenServer

  def start_link(args) do
    args = Keyword.take(args, [:cluster])
    args = Keyword.merge(args, name: __MODULE__)
    GenServer.start_link(__MODULE__, args, name: args[:name])
  end

  def init(args) do
    :net_kernel.monitor_nodes(true, node_type: :visible)
    {:ok, args}
  end

  def handle_info({:nodeup, _node, _node_type}, state) do
    cluster_name = state[:cluster]
    MyCluster.set_members(cluster_name)
    {:noreply, state}
  end

  def handle_info({:nodedown, _node, _node_type}, state) do
    cluster_name = state[:cluster]
    MyCluster.set_members(cluster_name)
    {:noreply, state}
  end
end

defmodule MyServer do
  use GenServer

  def start_link(name) do
    case GenServer.start_link(__MODULE__, [name], name: via_tuple(name)) do
      {:error, {:already_started, _}} ->
        :ignore

      other ->
        other
    end
  end

  def child_spec(name) do
    %{
      id: name,
      restart: :transient,
      start: {__MODULE__, :start_link, [name]}
    }
  end

  defp via_tuple(name) do
    MyRegistry.via_tuple({__MODULE__, name})
  end

  def whereis(name) do
    MyRegistry.whereis(via_tuple(name))
  end

  @impl GenServer
  def init([name]) do
    Process.flag(:trap_exit, true)
    {:ok, name}
  end

  @impl GenServer
  def handle_info({:EXIT, _, {:name_conflict, {{_, name}, _}, _registry, winner}}, state) do
    IO.inspect(conflict: name, looser: {self(), node(self())}, winner: {winner, node(winner)})
    {:stop, :shutdown, state}
  end
end
