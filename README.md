# Horde

Horde packages a distributed Supervisor and Registry built on δ-CRDTs.

[![Hex pm](http://img.shields.io/hexpm/v/horde.svg?style=flat)](https://hex.pm/packages/horde)[![CircleCI badge](https://circleci.com/gh/derekkraan/horde.png?circle-token=:circle-token)](https://circleci.com/gh/derekkraan/horde)

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

Public APIs of `Supervisor` and `Registry` have been reproduced as faithfully as possible. `Horde.Supervisor` and `Horde.Registry` should function more or less as drop-in replacements.

```elixir
{:ok, supervisor} = Horde.Supervisor.start_link([], node_id: :distributed_supervisor_1, strategy: :one_for_one)

Horde.Supervisor.start_child(supervisor, child_spec)
```

Horde runs inside Erlang clustering (but might later be ported to use other transport methods). Joining up supervisors or registries must be done manually:

```elixir
Horde.Tracker.join_hordes(supervisor_1, supervisor_2)
```

Leaving a horde is also possible:

```elixir
Horde.Tracker.leave_hordes(supervisor_2)
```

See the docs at [https://hexdocs.pm/horde](https://hexdocs.pm/horde).
