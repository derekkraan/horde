defmodule Horde.Cluster do
  require Logger

  @moduledoc """
  Public functions to join and leave hordes.

  Calling `Horde.Cluster.set_members/2` will join the given members in a cluster. Cluster membership is propagated via a CRDT, so setting it once on a single node is sufficient.
  ```elixir
  {:ok, sup1} = Horde.DynamicSupervisor.start_link([], name: :supervisor_1, strategy: :one_for_one)
  {:ok, sup2} = Horde.DynamicSupervisor.start_link([], name: :supervisor_2, strategy: :one_for_one)
  {:ok, sup3} = Horde.DynamicSupervisor.start_link([], name: :supervisor_3, strategy: :one_for_one)

  :ok = Horde.Cluster.set_members(:supervisor_1, [:supervisor_1, :supervisor_2, :supervisor_3])
  ```
  """

  @type name :: atom()
  @type member :: name() | {name(), node()}

  @spec set_members(horde :: GenServer.server(), members :: [member()], timeout :: timeout()) ::
          :ok | {:error, term()}
  def set_members(horde, members, timeout \\ 5000) do
    GenServer.call(horde, {:set_members, members}, timeout)
  end

  @doc """
  Get the members (nodes) of the horde
  """
  @spec members(horde :: GenServer.server()) :: [member()]
  def members(horde) do
    GenServer.call(horde, :members)
  end
end
