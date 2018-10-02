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

    index = XXHash.xxh32(term_to_string_identifier(identifier)) |> rem(Enum.count(members))

    Enum.at(members, index)
  end

  def has_quorum?(_members), do: true

  defp term_to_string_identifier(term), do: term |> :erlang.term_to_binary() |> Base.encode16()
end
