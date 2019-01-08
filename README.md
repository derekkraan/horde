# Horde

[![Hex pm](http://img.shields.io/hexpm/v/horde.svg?style=flat)](https://hex.pm/packages/horde) [![CircleCI badge](https://circleci.com/gh/derekkraan/horde.png?circle-token=:circle-token)](https://circleci.com/gh/derekkraan/horde)

Horde is comprised of `Horde.Supervisor`, a distributed supervisor, and `Horde.Registry`, a distributed registry. Horde is built on top of [DeltaCrdt](https://github.com/derekkraan/delta_crdt_ex).

Read the [full documentation](https://hexdocs.pm/horde) on hexdocs.pm.

There is also an [introductory blog post](https://medium.com/@derek.kraan2/introducing-horde-a-distributed-supervisor-in-elixir-4be3259cc142) and a [getting started guide](https://medium.com/@derek.kraan2/getting-started-with-hordes-distributed-supervisor-registry-f3017208e1ce). You can also find me in the Elixir slack channel #horde.

Daniel Azuma gave [a great talk](https://www.youtube.com/watch?v=nLApFANtkHs) at ElixirConf US 2018 where he demonstrated Horde's Supervisor and Registry.

Since Horde is built on CRDTs, it is eventually (as opposed to immediately) consistent, although it does sync its state with its neighbours rather aggressively. Cluster membership in Horde is fully dynamic; nodes can be added and removed at any time and Horde will continue to operate as expected. `Horde.Supervisor` also uses a hash ring to limit any possible race conditions to times when cluster membership is changing. 

`Horde.Registry` is API-compatible with Elixir's own Registry, although it does not yet support the `keys: :duplicate` option. For many use cases, it will be a drop-in replacement. `Horde.Supevisor` follows the API and behaviour of `DynamicSupervisor` as closely as possible. There will always be some difference between Horde and its standard library equivalents, if not in their APIs, then in their functionality. This is a necessary consequence of Horde's distributed nature.

## 1.0 release

Help us get to 1.0, please fill out our [very short survey](https://docs.google.com/forms/d/e/1FAIpQLSd0fGMuELJIKAiaR1XlvHKjpSo024cojktXjp4ASM7MSXTYfg/viewform?usp=sf_link) and report any issues you encounter when using Horde.

## Fault tolerance

If a node fails (or otherwise becomes unreachable) then Horde.Supervisor will redistribute processes among the remaining nodes.

You can choose what to do in the event of a network partition by specifying `:distribution_strategy` in the options for `Supervisor.start_link/2`. Setting this option to `Horde.UniformDistribution` (which is the default) distributes processes using a hash mechanism among all reachable nodes. In the event of a network partition, both sides of the partition will continue to operate. Setting it to `Horde.UniformQuorumDistribution` will operate in the same way, but will shut down if less than half of the cluster is reachable.

## CAP Theorem

Horde is eventually consistent, which means that Horde can guarantee availability and partition tolerancy. When Horde cluster membership is constant (ie, there is no node being removed or added), Horde also guarantees consistency. When adding or removing a node from the cluster, there will be a small window in which it is possible for race conditions to occur. Horde aggressively closes this window by distributing cluster membership updates as quickly as possible (after 5ms).

Example race condition: While a node is being added to the cluster, for a short period of time, some nodes know about the new node and some do not. If in this period of time, two nodes attempt to start the same process, this process will be started on two nodes simultaneously. This condition will persist until these two nodes have received deltas from each other and the state has converged (assigning the process to just one of the two nodes). The node that "loses" the process will kill it when it checks and realizes that it no longer owns it.

It's possible to run Horde and add and remove nodes without running into this limitation (depending on load), but one should always keep in mind that it's a plausible scenario.

## Graceful shutdown

Using `Horde.Supervisor.stop` will cause the local supervisor to stop and any processes it was running will be shut down and redistributed to remaining supervisers in the horde. (This should happen automatically if `:init.stop()` is called).

## Installation

Horde is [available in Hex](https://hex.pm/packages/horde).

The package can be installed by adding `horde` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:horde, "~> 0.4.0-rc.1"}
  ]
end
```

## Usage

Here is a small taste of Horde's usage. See the full docs at [https://hexdocs.pm/horde](https://hexdocs.pm/horde) for more information and examples. There is also an example application at `examples/hello_world` that you can refer to if you get stuck.

Starting `Horde.Supervisor`:

```elixir
defmodule MyApp.Application do
  use Application
  def start(_type, _args) do
    children = [
      {Horde.Supervisor, [name: MyApp.DistributedSupervisor, strategy: :one_for_one]}
    ]
    Supervsior.start_link(children, strategy: :one_for_one)
  end
end
```

Adding a child to the supervisor:

```elixir
Horde.Supervisor.start_child(MyApp.DistributedSupervisor, %{id: :gen_server, start: {GenServer, :start_link, []}})
```

And so on. The public API should be the same as `Supervisor` (and please open an issue if you find a difference).

Joining supervisors into a single distributed supervisor can be done using `Horde.Cluster`:

```elixir
{:ok, supervisor_1} = Horde.Supervisor.start_link([], name: :distributed_supervisor_1, strategy: :one_for_one)
{:ok, supervisor_2} = Horde.Supervisor.start_link([], name: :distributed_supervisor_2, strategy: :one_for_one)
{:ok, supervisor_3} = Horde.Supervisor.start_link([], name: :distributed_supervisor_3, strategy: :one_for_one)

Horde.Cluster.join_hordes(supervisor_1, supervisor_2)
Horde.Cluster.join_hordes(supervisor_2, supervisor_3)
# supervisor_1, supervisor_2 and supervisor_3 will be joined in a single cluster.

Horde.Cluster.leave_hordes(supervisor_2)
# supervisor_2 will no longer be part of the cluster, but supervisor_1 and supervisor_3 will remain.
```

If you tell `Horde.Supervisor` to leave the horde, then it will kill all processes and disassociate them (to be picked up by other nodes). This can be used to implement graceful shutdown / failover.

# Contributing

Contributions are welcome! Feel free to open an issue if you'd like to discuss a problem or a possible solution. Pull requests are much appreciated.
