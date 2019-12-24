defmodule TestApp.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  def start(_type, _args) do
    children = [
      {Horde.DynamicSupervisor,
       name: TestSup, strategy: :one_for_one, delta_crdt_options: [sync_interval: 30]},
      {Horde.Registry, name: TestReg, keys: :unique, delta_crdt_options: [sync_interval: 30]}
    ]

    opts = [strategy: :one_for_one, name: TestApp.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
