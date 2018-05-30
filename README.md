# Horde

Horde is an eventually-consistent distributed supervisor (`Horde.Supervisor`) and registry (`Horde.Registry`). 

Horde is built using a add-wins last-write-wins δ-CRDT map. By using a CRDT, Horde is guaranteed to eventually convergeon a single representation of the data.

`Horde.Supervisor` makes use of a hash ring to limit any possible race conditions to times when cluster membership is changing.

Horde attempts to replicate the public API of both `Supervisor` and `Registry` as much as possible. In some cases it will be a drop-in replacement. Some calls will also closely mirror functionality of their standard library counterparts but in some other cases this is not possible, given the distributed nature of Horde.

[![Hex pm](http://img.shields.io/hexpm/v/horde.svg?style=flat)](https://hex.pm/packages/horde)

[![CircleCI badge](https://circleci.com/gh/derekkraan/horde.png?circle-token=:circle-token)](https://circleci.com/gh/derekkraan/horde)

## Fault tolerance

If a node fails (or otherwise becomes unreachable) then Horde.Supervisor will redistribute processes among the remaining nodes.

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `horde` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:horde, "~> 0.1.0"}
  ]
end
```

## Usage

See the full docs at [https://hexdocs.pm/horde](https://hexdocs.pm/horde).

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

Joining supervisors into a single distributed supervisor can be done using `Horde.Tracker`:

```elixir
{:ok, supervisor} = Horde.Supervisor.start_link([], name: :distributed_supervisor_1, strategy: :one_for_one)

Horde.Tracker.join_hordes(supervisor_1, supervisor_2)

Horde.Tracker.leave_hordes(supervisor_2)
```

If you tell `Horde.Supervisor` to leave the horde, then it will kill all processes and disassociate them (to be picked up by other nodes). This can be used to implement graceful shutdown / failover.

# Contributing

Contributions are welcome! Feel free to open an issue if you'd like to discuss a problem or a possible solution. Pull requests are much appreciated.

If you end up using `Horde` then feel free to ping me on twitter: @derekkraan.
