defmodule HelloWorld.Application do
  @moduledoc false

  use Application

  def start(_type, _args) do
    # List all child processes to be supervised
    children = [
      {Horde.Registry,
       [name: HelloWorld.HelloRegistry, keys: :unique, members: registry_members()]},
      {Horde.Supervisor,
       [
         name: HelloWorld.HelloSupervisor,
         strategy: :one_for_one,
         max_restarts: 100_000,
         max_seconds: 1,
         members: supervisor_members()
       ]},
      %{
        id: HelloWorld.ClusterConnector,
        restart: :transient,
        start:
          {Task, :start_link,
           [
             fn ->
               Process.sleep(500)
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

  defp registry_members do
    [
      {HelloWorld.HelloRegistry, :"count1@127.0.0.1"},
      {HelloWorld.HelloRegistry, :"count2@127.0.0.1"}
    ]
  end

  defp supervisor_members do
    [
      {HelloWorld.HelloSupervisor, :"count1@127.0.0.1"},
      {HelloWorld.HelloSupervisor, :"count2@127.0.0.1"}
    ]
  end
end
