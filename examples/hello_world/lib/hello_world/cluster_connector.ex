defmodule HelloWorld.ClusterConnector do
  require Logger

  def connect() do
    connect(System.get_env("HELLO_NODES"))
  end

  def connect(nil), do: nil
  def connect(""), do: nil

  def connect(nodes) do
    Logger.debug("connect to nodes #{inspect(nodes)}")

    String.split(nodes)
    |> Enum.map(&String.to_atom/1)
    |> Enum.each(&Node.connect/1)
  end
end
