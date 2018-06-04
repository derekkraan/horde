defmodule Horde.UniformDistribution do
  @moduledoc """
  Distributes processes to nodes uniformly using a hash ring
  """

  def choose_node(identifier, members) do
    members =
      members
      |> Enum.filter(fn
        {_, {:alive, _}} -> true
        _ -> false
      end)
      |> Enum.sort_by(fn {node_id, _} -> node_id end)

    index = XXHash.xxh32("#{identifier}") |> rem(Enum.count(members))

    Enum.at(members, index)
  end

  def has_quorum?(_members), do: true
end
