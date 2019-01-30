defmodule HelloWorld.Application do
  @moduledoc false

  use Application

  def start(_type, _args) do
    # List all child processes to be supervised
    children = [
      {Horde.Registry, [name: HelloWorld.HelloRegistry, keys: :unique]},
      {Horde.Supervisor,
       [
         name: HelloWorld.HelloSupervisor,
         strategy: :one_for_one,
         max_restarts: 100_000,
         max_seconds: 1
       ]},
      %{
        id: HelloWorld.ClusterConnector,
        restart: :transient,
        start:
          {Task, :start_link,
            [
              fn ->
                HelloWorld.ClusterConnector.connect()
                HelloWorld.HordeConnector.connect()
                :timer.sleep(1000)
                Horde.Supervisor.start_child(HelloWorld.HelloSupervisor, HelloWorld.SayHello)
              end
            ]}
      }
    ]

    opts = [strategy: :one_for_one, name: HelloWorld.Supervisor]
    Supervisor.start_link(children, opts)
  end

  def how_many?() do
    Horde.Registry.meta(HelloWorld.HelloRegistry, "count")
  end
end
