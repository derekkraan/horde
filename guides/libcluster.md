# Setting up a Cluster

Horde doesn't provide functionality to set up your cluster, we recommend you use [`libcluster`](https://hexdocs.pm/libcluster/readme.html) for this purpose.

There are two strategies you can use to integrate libcluster with Horde:

## Static Cluster Membership

If you will not be adding or removing members from the cluster dynamically, then you can set up libcluster and tell Horde about the members of your cluster. For example, if you run your cluster on bare metal hardware and have a fixed number of servers.

```elixir
members = [
  {:node1, MyHordeSupervisor},
  {:node2, MyHordeSupervisor},
  {:node3, MyHordeSupervisor},
  {:node4, MyHordeSupervisor}
]

children = [
  {Horde.Supervisor, name: MyHordeSupervisor, strategy: :one_for_one, members: members},
  ...
]
```

This is the simplest approach. You tell Horde which members are supposed to be in the cluster, and if they are available, Horde will include them in the cluster.

## Dynamic Cluster Membership

If you will be adding and removing nodes from your cluster constantly, and don't want to repackage your application every time you do this, then you will need to perform a couple of extra steps.

In this scenario, you will need to implement a [module-based Supervisor](Horde.Supervisor.html#module-module-based-supervisor)

```elixir
defmodule MyHordeSupervisor do
  use Horde.Supervisor

  def init(options) do
    {:ok, Keyword.put(options, :members, get_members())}
  end

  defp get_members() do
    Enum.map(Node.list(), fn node -> {MyHordeSupervisor, node} end)
  end
end
```

Now every time `MyHordeSupervisor` gets started or restarted, it will compute the members based on the currently connected members.

We also need a separate process that will listen for `{:nodeup, node}` and `{:nodedown, node}` events and adjust the members of the Horde cluster accordingly. Put this in your supervision tree underneath `MyHordeSupervisor`.

```elixir
defmodule NodeListener do
  use GenServer

  def init(_) do
    :net_kernel.monitor_nodes(true, node_type: :visible)
    {:ok, nil}
  end

  def handle_info({:nodeup, _node}, state) do
    set_members(MyHordeSupervisor)
    {:noreply, state}
  end

  def handle_info({:nodedown, _node}, state) do
    set_members(MyHordeSupervisor)
    {:noreply, state}
  end

  defp set_members(name) do
    members = Enum.map(Node.list(), fn node -> {name, node} end)
    :ok = Horde.Cluster.set_members(name, members)
  end
end
```
