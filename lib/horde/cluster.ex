defmodule Horde.Cluster do
  require Logger

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
  """

  @doc """
  Join two hordes into one big horde. Calling this once will inform every node in each horde of every node in the other horde. Leave the hordes by calling `Horde.Supervisor.stop/1` or `Horde.Registry.stop/1`
  """
  @spec join_hordes(horde :: GenServer.server(), other_horde :: GenServer.server()) ::
          :ok | {:error, term()}
  def join_hordes(horde, other_horde, timeout \\ 5000) do
    GenServer.call(horde, {:join_hordes, other_horde}, timeout)
  catch
    :exit, {:timeout, details} ->
      Logger.debug(fn -> "Joining a horde failed. Details: #{inspect({:timeout, details})}" end)
      {:error, {:timeout, details}}
  end

  @doc """
  Get the members (nodes) of the horde
  """
  @spec members(horde :: GenServer.server()) :: map()
  def members(horde) do
    GenServer.call(horde, :members)
  end
end
