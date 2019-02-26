defmodule Horde.UniformQuorumDistribution do
  @behaviour Horde.DistributionStrategy

  @moduledoc """
  Distributes processes to nodes uniformly using a hash ring. Contains a quorum mechanism to handle netsplits.
  """
  require Integer

  def choose_node(identifier, members) do
    if has_quorum?(members) do
      Horde.UniformDistribution.choose_node(identifier, members)
    else
      {:error, "quorum not met"}
    end
  end

  def has_quorum?([]), do: false

  def has_quorum?(members) do
    case active_nodes(members) do
      [] ->
        nil

      members ->
        alive_count =
          Enum.count(members, fn
            %{status: :alive} -> true
            _ -> false
          end)

        alive_count / Enum.count(members) > 0.5
    end
  end

  defp active_nodes(members) do
    nodes =
      members
      |> Enum.reject(fn
        %{status: :shutting_down} -> true
        _ -> false
      end)
      |> Enum.sort_by(fn
        %{name: name} -> name
      end)

    node_count = Enum.count(nodes)

    if node_count > 0 && Integer.is_even(node_count) do
      [_ | nodes] = nodes
      nodes
    else
      nodes
    end
  end
end
