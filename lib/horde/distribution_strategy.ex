defmodule Horde.DistributionStrategy do
  @type t :: module()

  @moduledoc """
  Define your own distribution strategy by implementing this behaviour and configuring Horde to use it.

  A few distribution strategies are included in Horde, namely:

  - `Horde.UniformDistribution`
  - `Horde.UniformQuorumDistribution`
  - `Horde.UniformRandomDistribution`
  """
  @callback choose_node(identifier :: String.t(), members :: [Horde.DynamicSupervisor.Member.t()]) ::
              {:ok, Horde.DynamicSupervisor.Member.t()} | {:error, reason :: String.t()}
  @callback has_quorum?(members :: [Horde.DynamicSupervisor.Member.t()]) :: boolean()
end
