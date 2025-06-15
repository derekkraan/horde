defmodule Dynamic.Application do
  @moduledoc false

  use Application

  def start(_type, _args) do
    # List all child processes to be supervised
    children = [
      {Horde.Registry, [name: Dynamic.EntityRegistry, keys: :unique]},
      {Horde.Supervisor,
       [
         name: Dynamic.EntitySupervisor,
         strategy: :one_for_one,
         distribution_strategy: Horde.UniformQuorumDistribution,
         max_restarts: 100_000,
         max_seconds: 1
       ]},
      NodeListener,
      unquote(if(Mix.env() != :test, do: quote(do: {Cluster.Supervisor, [Application.get_env(:libcluster, :topologies)]}))),
      %{
        id: Dynamic.ClusterConnector,
        restart: :transient,
        start:
          {Task, :start_link,
           [
             fn ->
               Horde.Supervisor.wait_for_quorum(Dynamic.EntitySupervisor, 30_000)
             end
           ]}
      }
    ]
    |> Enum.filter(&(&1))

    opts = [strategy: :one_for_one, name: Dynamic.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
