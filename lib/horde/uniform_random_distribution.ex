defmodule Horde.UniformRandomDistribution do
  @behaviour Horde.DistributionStrategy

  @moduledoc """
  Distributes processes with an uniform probability to
  any node that is alive.
  """

  @doc """
  Selects a random alive node.
  """
  def choose_node(_identifier, members) do
    members
    |> Enum.filter(&match?(%{status: :alive}, &1))
    |> case do
      [] ->
        {:error, :no_alive_nodes}

      members ->
        chosen_member =
          Enum.shuffle(members)
          |> List.first()

        {:ok, chosen_member}
    end
  end

  @doc """
  Quorum checks are not enforced, so the process will be
  (re)started on  both sides of a netsplit.
  """
  def has_quorum?(_members), do: true
end
