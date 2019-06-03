defmodule Horde.UniformDistribution do
  @behaviour Horde.DistributionStrategy

  @moduledoc """
  Distributes processes to nodes uniformly using a hash ring
  """

  def choose_node(identifier, members) do
    members =
      members
      |> Enum.filter(fn
        %{status: :alive} -> true
        _ -> false
      end)
      |> Enum.sort_by(fn %{name: name} -> name end)

    case Enum.count(members) do
      0 ->
        {:error, :no_alive_nodes}

      count ->
        index = hash(term_to_string_identifier(identifier)) |> rem(count)
        {:ok, Enum.at(members, index)}
    end
  end

  defp hash(identifier) when is_integer(identifier), do: identifier
  defp hash(identifier), do: :erlang.phash2(identifier)

  def has_quorum?(_members), do: true

  defp term_to_string_identifier(term), do: term |> :erlang.term_to_binary() |> Base.encode16()
end
