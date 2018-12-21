defmodule HelloHelpers do
  def reconnect() do
    HelloWorld.ClusterConnector.connect()
    HelloWorld.HordeConnector.connect()
  end
end
