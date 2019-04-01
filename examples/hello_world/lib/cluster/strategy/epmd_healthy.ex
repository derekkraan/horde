defmodule Cluster.Strategy.EpmdHealthy do
  @moduledoc """
  This clustering strategy relies on Erlang's built-in distribution protocol.

  You can have lib automatically connect nodes on startup for you by configuring
  the strategy like below:

  config :lib,
  topologies: [
  epmd_example: [
  strategy: #{__MODULE__},
  config: [hosts: [:"a@127.0.0.1", :"b@127.0.0.1"]]]]
  """

  use GenServer
  use Cluster.Strategy

  alias Cluster.Strategy.State

  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  def init(state) do
    connect(state)
    Process.send_after(self(), :connect, 5_000)
    {:ok, state}
  end

  def handle_info(:connect, state) do
    connect(state)
    Process.send_after(self(), :connect, 5_000)
    {:noreply, state}
  end

  defp connect([%State{config: config} = state]) do
    case Keyword.get(config, :hosts, []) do
      [] ->
        :ignore

      nodes when is_list(nodes) ->
        Cluster.Strategy.connect_nodes(state.topology, state.connect, state.list_nodes, nodes)
        :ignore
    end
  end
end
