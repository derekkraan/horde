# Horde

Horde is an eventually-consistent distributed supervisor (`Horde.Supervisor`) and registry (`Horde.Registry`). Horde is built on top of an add-wins last-write-wins [δ-CRDT](https://github.com/derekkraan/delta_crdt_ex). Horde tracks all child specs in the CRDT along with the nodes on which they are running. Since CRDTs are guaranteed to eventually converge, we can guarantee that Horde will also converge to a single representation of the shared state.

Cluster membership in Horde is fully dynamic. Nodes can be added and removed at any time and Horde will keep working like you expect it to.

You can use Horde to build fault-tolerant distributed systems that need either a global registry or a global supervisor, or both.

`Horde.Supervisor` makes use of a hash ring to limit any possible race conditions to times when cluster membership is changing.

Horde attempts to replicate the public API of both `Supervisor` and `Registry` as much as possible. In some cases it will be a drop-in replacement. Some calls will also closely mirror functionality of their standard library counterparts but in some other cases this is not possible, given the distributed nature of Horde.

[![Hex pm](http://img.shields.io/hexpm/v/horde.svg?style=flat)](https://hex.pm/packages/horde)

[![CircleCI badge](https://circleci.com/gh/derekkraan/horde.png?circle-token=:circle-token)](https://circleci.com/gh/derekkraan/horde)

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
    {:horde, "~> 0.1.5"}
  ]
end
```

## Usage

See the full docs at [https://hexdocs.pm/horde](https://hexdocs.pm/horde).

There is also an example app at `examples/hello_world`.

Putting `Horde.Supervisor` in a supervisor:

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

And so on. The public API should be the same as `Supervisor` (and please open an issue if it turns out not to be).

Joining supervisors into a single distributed supervisor can be done using `Horde.Cluster`:

```elixir
{:ok, supervisor} = Horde.Supervisor.start_link([], name: :distributed_supervisor_1, strategy: :one_for_one)

Horde.Cluster.join_hordes(supervisor_1, supervisor_2)

Horde.Cluster.leave_hordes(supervisor_2)
```

If you tell `Horde.Supervisor` to leave the horde, then it will kill all processes and disassociate them (to be picked up by other nodes). This can be used to implement graceful shutdown / failover.

# Contributing

Contributions are welcome! Feel free to open an issue if you'd like to discuss a problem or a possible solution. Pull requests are much appreciated.

If you end up using `Horde` then feel free to ping me on twitter: @derekkraan.
