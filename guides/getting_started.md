# Getting Started

This guide shows you how to get started with Horde. Code samples come from the example HelloWorld app in `examples/hello_world`.

## Erlang clustering

Horde relies on Erlang's built in clustering. To make this work, each node in our cluster needs a unique name, and each node must be started using the same cookie. We can try this out locally like so:

```bash
iex --name node1@127.0.0.1 --cookie asdf -S mix
iex --name node2@127.0.0.1 --cookie asdf -S mix
iex --name node3@127.0.0.1 --cookie asdf -S mix
```

In this example each node has a unique name, and they all share the same cookie. Now we can connect these nodes by running the following code:

```elixir
Node.connect(:"node2@127.0.0.1")
```

Run `Node.list()` to confirm that the nodes are connected.

Horde assumes that you will manage Erlang clustering yourself. There are libraries that will help you do this. Continue reading the getting started guide and when you are getting ready to deploy your application, read about [how to set up a cluster](libcluster.html).

## Starting Horde.DynamicSupervisor

Horde.DynamicSupervisor is API-compatible with Elixir's DynamicSupervisor. There are extra arguments that you can provide, but the basic recipe stays the same:

```elixir
defmodule HelloWorld.Application do
  use Application

  def start(_type, _args) do
    children = [
      {Horde.DynamicSupervisor, [name: HelloWorld.HelloSupervisor, strategy: :one_for_one]},
    ]

    opts = [strategy: :one_for_one, name: HelloWorld.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

This is also where you can set additional options for Horde.DynamicSupervisor:
- `:members`, a list of members (if your cluster will have static membership)
- `:distribution_strategy`, the distribution strategy (`Horde.UniformDistribution` is default)
- `:delta_crdt_options`, for tuning the delta CRDT that underpins Horde

See the documentation for `Horde.DynamicSupervisor` for more information.

## Starting Horde.Registry

Horde.DynamicSupervisor is spreading your processes out over the cluster, but how do you know where all these processes are? Horde.Registry is the answer. We want Horde.Registry to be above Horde.DynamicSupervisor in the start-up order.

This is what our example above looks like with Horde.Registry added in:

```elixir
defmodule HelloWorld.Application do
  use Application

  def start(_type, _args) do
    children = [
      {Horde.Registry, [name: HelloWorld.HelloRegistry, keys: :unique]},
      {Horde.DynamicSupervisor, [name: HelloWorld.HelloSupervisor, strategy: :one_for_one]},
    ]

    opts = [strategy: :one_for_one, name: HelloWorld.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

There are also some additional options for Horde.Registry:
- `:members`, a list of members (if your cluster will have static membership)
- `:delta_crdt_options`, for tuning the delta CRDT that underpins Horde

See the documentation for `Horde.Registry` for more information.

## Running a GenServer

Let's create a very simple GenServer that we will use to run in our example application to test things out a little.

```elixir
defmodule HelloWorld.SayHello do
  use GenServer
  require Logger

  def child_spec(opts) do
    name = Keyword.get(opts, :name, __MODULE__)

    %{
      id: "#{__MODULE__}_#{name}",
      start: {__MODULE__, :start_link, [name]},
      shutdown: 10_000,
      restart: :transient
    }
  end

  def start_link(name) do
    case GenServer.start_link(__MODULE__, [], name: via_tuple(name)) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        Logger.info("already started at #{inspect(pid)}, returning :ignore")
        :ignore
    end
  end

  def init(_args) do
    {:ok, nil}
  end

  def via_tuple(name), do: {:via, Horde.Registry, {HelloWorld.HelloRegistry, name}}
end
```

This GenServer can be started by running the following line of code: `Horde.DynamicSupervisor.start_child(HelloWorld.HelloSupervisor, HelloWorld.SayHello)`.

Once running, you can address this GenServer with the following line of code: `GenServer.call(via_tuple(HelloWorld.SayHello), msg)`.

## Next Steps

Now you should have a working installation of Horde. There is more information available in the other guides, so don't forget to read those too. If you get stuck or have suggestions on how this guide could be improved, please [open an issue](https://github.com/derekkraan/horde/issues/new?title=Improve Getting Started guide) on Github.
