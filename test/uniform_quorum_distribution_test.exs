defmodule UniformQuorumDistributionTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  property "chooses one of the members" do
    member =
      ExUnitProperties.gen all node_id <- integer(1..100_000),
                               status <- StreamData.member_of([:alive, :dead, :shutting_down]),
                               name <- binary(),
                               pid <- atom(:alias) do
        {node_id, {status, %{pid: pid, name: name}}}
      end

    check all members <-
                uniq_list_of(member, min_length: 2, uniq_fun: fn {node_id, _} -> node_id end),
              identifier <- string(:alphanumeric) do
      partition_a = members

      partition_b =
        members
        |> Enum.map(fn
          {node_id, {:alive, %{name: name, pid: pid}}} ->
            {node_id, {:dead, %{name: name, pid: pid}}}

          {node_id, {:dead, %{name: name, pid: pid}}} ->
            {node_id, {:alive, %{name: name, pid: pid}}}

          node_spec ->
            node_spec
        end)

      chosen_a = Horde.UniformQuorumDistribution.choose_node(identifier, partition_a)
      chosen_b = Horde.UniformQuorumDistribution.choose_node(identifier, partition_b)

      Enum.all?(members, fn
        {_, {:shutting_down, _}} -> true
        _ -> false
      end)
      |> if do
        assert 0 = [chosen_a, chosen_b] |> Enum.count(fn x -> x end)
      else
        assert 1 = [chosen_a, chosen_b] |> Enum.count(fn x -> x end)
      end
    end
  end
end
