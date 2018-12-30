defmodule Horde.DistributionStrategy do
  @moduledoc """
  Define your own distribution strategy by implementing this behaviour and configuring Horde to use it.

  See `Horde.UniformQuorumDistribution` and `Horde.UniformDistribution` for examples.
  """
  @callback choose_node(identifier :: String.t(), members :: [Horde.Supervisor.Member.t()]) ::
              {:ok, Horde.Supervisor.Member.t()} | {:error, reason :: String.t()}
  @callback has_quorum?(members :: [Horde.Supervisor.Member.t()]) :: boolean()
end
