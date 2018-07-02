defmodule HelloWorld.HordeConnector do
  require Logger

  def connect() do
    Node.list()
    |> Enum.each(fn node ->
      Horde.Cluster.join_hordes(HelloWorld.HelloSupervisor, {HelloWorld.HelloSupervisor, node})
      Horde.Cluster.join_hordes(HelloWorld.HelloRegistry, {HelloWorld.HelloRegistry, node})
    end)
  end
end
