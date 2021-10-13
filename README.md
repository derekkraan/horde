# Horde [![Hex pm](http://img.shields.io/hexpm/v/horde.svg?style=flat)](https://hex.pm/packages/horde) [![CircleCI badge](https://circleci.com/gh/derekkraan/horde.png?circle-token=:circle-token)](https://circleci.com/gh/derekkraan/horde)

Distribute your application over multiple servers with Horde.

Horde is comprised of `Horde.DynamicSupervisor`, a distributed supervisor, and `Horde.Registry`, a distributed registry. Horde is built on top of [DeltaCrdt](https://github.com/derekkraan/delta_crdt_ex).

Read the [full documentation](https://hexdocs.pm/horde) on hexdocs.pm.

There is an [introductory blog post](https://moosecode.nl/blog/introducing_horde) and a [getting started guide](https://moosecode.nl/blog/getting_started_horde). You can also find me in the Elixir slack channel #horde.

Daniel Azuma gave [a great talk](https://www.youtube.com/watch?v=nLApFANtkHs) at ElixirConf US 2018 where he demonstrated Horde's Supervisor and Registry.

Since Horde is built on CRDTs, it is eventually (as opposed to immediately) consistent, although it does sync its state with its neighbours rather aggressively. Cluster membership in Horde is fully dynamic; nodes can be added and removed at any time and Horde will continue to operate as expected. `Horde.DynamicSupervisor` also uses a hash ring to limit any possible race conditions to times when cluster membership is changing. 

`Horde.Registry` is API-compatible with Elixir's own Registry, although it does not yet support the `keys: :duplicate` option. For many use cases, it will be a drop-in replacement. `Horde.DynamicSupervisor` follows the API and behaviour of `DynamicSupervisor` as closely as possible. There will always be some difference between Horde and its standard library equivalents, if not in their APIs, then in their functionality. This is a necessary consequence of Horde's distributed nature.

## 1.0 release

Help us get to 1.0, please fill out our [very short survey](https://docs.google.com/forms/d/e/1FAIpQLSd0fGMuELJIKAiaR1XlvHKjpSo024cojktXjp4ASM7MSXTYfg/viewform?usp=sf_link) and report any issues you encounter when using Horde.

## Fault tolerance

If a node fails (or otherwise becomes unreachable) then Horde.DynamicSupervisor will redistribute processes among the remaining nodes.

You can choose what to do in the event of a network partition by specifying `:distribution_strategy` in the options for `Horde.DynamicSupervisor.start_link/2`. Setting this option to `Horde.UniformDistribution` (which is the default) distributes processes using a hash mechanism among all reachable nodes. In the event of a network partition, both sides of the partition will continue to operate. Setting it to `Horde.UniformQuorumDistribution` will operate in the same way, but will shut down if less than half of the cluster is reachable.

## CAP Theorem

Horde is eventually consistent, which means that Horde can guarantee availability and partition tolerancy. Horde cannot guarantee consistency. This means you may end up with duplicate processes in your cluster. Horde does aggressively synchronize between nodes (this is also tunable), but ultimately, depending on the tuning parameters you choose and the quality of the network, there are conditions under which it is possible to have duplicate processes in your cluster. Horde.Registry terminates duplicate processes as soon as they are discovered with a special exit code, so you'll always know when this is happening. See [this page in the docs](https://hexdocs.pm/horde/eventual_consistency.html#horde-registry-merge-conflict) for more details.

_NOTE: Since Horde 0.6.0, Horde.DynamicSupervisor ignores the `id` of a child spec (as Elixir.DynamicSupervisor does), and therefore does not guarantee that each `id` will be unique in the cluster (as it did pre-0.6.0). If you want to uniquely name your processes in a cluster, use Horde.Registry for this purpose. Having both Horde.DynamicSupervisor and Horde.Registry checking for uniqueness was subject to a race condition where Horde.DynamicSupervisor would choose process A to survive and Horde.Registry would choose process B to survive, resulting in both processes being killed._

## Graceful shutdown

Using `Horde.DynamicSupervisor.stop/3` will cause the local supervisor to stop and any processes it was running will be shut down and redistributed to remaining supervisors in the horde. (This should happen automatically if `:init.stop()` is called).

## Installation

Horde is [available in Hex](https://hex.pm/packages/horde).

The package can be installed by adding `horde` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:horde, "~> 0.7.0"}
  ]
end
```

## Usage

Here is a small taste of Horde's usage. See the full docs at [https://hexdocs.pm/horde](https://hexdocs.pm/horde) for more information and examples. There is also an example application at `examples/hello_world` that you can refer to if you get stuck.

Starting `Horde.DynamicSupervisor`:

```elixir
defmodule MyApp.Application do
  use Application
  def start(_type, _args) do
    children = [
      {Horde.DynamicSupervisor, [name: MyApp.DistributedSupervisor, strategy: :one_for_one]}
    ]
    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
```

Adding a child to the supervisor:

```elixir
# Add a Task
Horde.DynamicSupervisor.start_child(MyApp.DistributedSupervisor, %{id: :task, start: {Task, :start_link, [:infinity]}})

# Add an Agent
Horde.DynamicSupervisor.start_child(MyApp.DistributedSupervisor, %{id: :agent, start: {Agent, :start_link, [fn -> %{} end]}})

# Add a GenServer: You need a previously defined GenServer to call the one
# liner below.  We have a test ("graceful shutdown") in
# `test/supervisor_test.exs` that exercises and displays that behavior. After
# defined, it would be very similar to this:
Horde.DynamicSupervisor.start_child(MyApp.DistributedSupervisor, %{id: :gen_server, start: {GenServer, :start_link, [DefinedGenServer, {500, pid}]}})
```

And so on. The public API should be the same as `Elixir.DynamicSupervisor` (and please open an issue if you find a difference).

Joining supervisors into a single distributed supervisor can be done using `Horde.Cluster`:

```elixir
{:ok, supervisor_1} = Horde.DynamicSupervisor.start_link(name: :distributed_supervisor_1, strategy: :one_for_one)
{:ok, supervisor_2} = Horde.DynamicSupervisor.start_link(name: :distributed_supervisor_2, strategy: :one_for_one)
{:ok, supervisor_3} = Horde.DynamicSupervisor.start_link(name: :distributed_supervisor_3, strategy: :one_for_one)

Horde.Cluster.set_members(:distributed_supervisor_1, [:distributed_supervisor_1, :distributed_supervisor_2, :distributed_supervisor_3])
# supervisor_1, supervisor_2 and supervisor_3 will be joined in a single cluster.
```

# Contributing

Contributions are welcome! Feel free to open an issue if you'd like to discuss a problem or a possible solution. Pull requests are much appreciated.
