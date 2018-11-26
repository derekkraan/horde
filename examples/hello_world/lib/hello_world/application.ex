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
         strategy: :one_for_one
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
