defmodule Horde.UniformQuorumDistribution do
  @moduledoc """
  Distributes processes to nodes uniformly using a hash ring. Contains a quorum mechanism to handle netsplits.
  """
  require Integer

  def choose_node(identifier, members) do
    if has_quorum?(members) do
      Horde.UniformDistribution.choose_node(identifier, members)
    else
      nil
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
            {_, {:alive, _, _}} -> true
            _ -> false
          end)

        alive_count / Enum.count(members) > 0.5
    end
  end

  defp active_nodes(members) do
    nodes =
      members
      |> Enum.reject(fn
        {_, {:shutting_down, _, _}} -> true
        _ -> false
      end)
      |> Enum.sort_by(fn {node_id, _} -> node_id end)

    node_count = Enum.count(nodes)

    if node_count > 0 && Integer.is_even(node_count) do
      [_ | nodes] = nodes
      nodes
    else
      nodes
    end
  end
end
