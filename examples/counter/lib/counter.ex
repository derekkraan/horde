defmodule Counter do
  @moduledoc false

  use Application

  def start(_type, _args) do
    children = [
      {Horde.Registry, [name: Counter.Registry, keys: :unique, members: registry_members()]},
      {Horde.Supervisor,
       [
         name: Counter.CounterSupervisor,
         strategy: :one_for_one,
         distribution_strategy: Horde.UniformQuorumDistribution,
         max_restarts: 100_000,
         max_seconds: 1,
         members: supervisor_members()
       ]},
      {Cluster.Supervisor, [Application.get_env(:libcluster, :topologies)]}
    ]

    opts = [strategy: :one_for_one, name: Counter.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp registry_members do
    Application.get_env(:libcluster, :topologies)
    |> get_in([:counter_cluster, :config, :hosts])
    |> Enum.map(fn name -> {Counter.Registry, name} end)
  end

  defp supervisor_members do
    Application.get_env(:libcluster, :topologies)
    |> get_in([:counter_cluster, :config, :hosts])
    |> Enum.map(fn name -> {Counter.CounterSupervisor, name} end)
  end
end
