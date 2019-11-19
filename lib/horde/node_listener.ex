defmodule Horde.NodeListener do
  @moduledoc """
  A cluster membership manager.

  Horde.NodeListener monitors nodes in BEAM's distribution system and
  automatically adds and removes those marked as `visible` from the cluster it's
  managing
  """
  use GenServer

  # API

  @spec start_link(atom()) :: GenServer.on_start()
  def start_link(cluster),
    do: GenServer.start_link(__MODULE__, cluster, name: listener_name(cluster))

  @spec initial_set(atom()) :: :ok
  def initial_set(cluster) do
    GenServer.cast(listener_name(cluster), :initial_set)
  end

  # GenServer callbacks

  def init(cluster) do
    :net_kernel.monitor_nodes(true, node_type: :visible)
    {:ok, cluster}
  end

  def handle_cast(:initial_set, cluster) do
    set_members(cluster)
    {:noreply, cluster}
  end

  def handle_info({:nodeup, _node, _node_type}, cluster) do
    set_members(cluster)
    {:noreply, cluster}
  end

  def handle_info({:nodedown, _node, _node_type}, cluster) do
    set_members(cluster)
    {:noreply, cluster}
  end

  def handle_info(_, cluster), do: {:noreply, cluster}

  # Helper functions

  defp listener_name(cluster), do: Module.concat(cluster, NodeListener)

  defp set_members(cluster) do
    members = Enum.map(nodes(), fn node -> {cluster, node} end)
    :ok = Horde.Cluster.set_members(cluster, members)
  end

  defp nodes(), do: Node.list([:visible, :this])
end
