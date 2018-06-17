defmodule Horde.Cluster do
  @moduledoc """
  Public functions to join and leave hordes.

  Calling `Horde.Cluster.join_hordes/2` will join two nodes in the cluster. Cluster membership is associative so joining a node to another node is the same as joining a node to every node in the second node's cluster.
  ```elixir
  {:ok, sup1} = Horde.Supervisor.start_link([], name: :supervisor_1, strategy: :one_for_one)
  {:ok, sup2} = Horde.Supervisor.start_link([], name: :supervisor_2, strategy: :one_for_one)
  {:ok, sup3} = Horde.Supervisor.start_link([], name: :supervisor_3, strategy: :one_for_one)

  :ok = Horde.Cluster.join_hordes(sup1, sup2)
  :ok = Horde.Cluster.join_hordes(sup2, sup3)
  ```

  Calling `Horde.Cluster.leave_hordes/1` will instruct a node to remove itself from the cluster.
  ```elixir
  :ok = Horde.Cluster.leave_hordes(sup1)
  ```
  """

  @doc """
  Join two hordes into one big horde. Calling this once will inform every node in each horde of every node in the other horde.
  """
  @spec join_hordes(horde :: pid(), other_horde :: pid()) :: :ok
  def join_hordes(horde, other_horde) do
    GenServer.cast(horde, {:join_hordes, other_horde})
  end

  @doc """
  Remove an instance of horde from the greater hordes.
  """
  @spec leave_hordes(horde :: pid()) :: :ok
  def leave_hordes(horde) do
    GenServer.cast(horde, :leave_hordes)
  end

  @doc """
  Get the members (nodes) of the horde
  """
  @spec members(horde :: pid()) :: map()
  def members(horde) do
    GenServer.call(horde, :members)
  end
end
