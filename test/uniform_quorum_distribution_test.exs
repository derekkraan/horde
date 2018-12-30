defmodule UniformQuorumDistributionTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  property "chooses one of the members" do
    member =
      ExUnitProperties.gen all node_id <- integer(1..100_000),
                               status <- StreamData.member_of([:alive, :dead, :shutting_down]),
                               name <- binary(),
                               pid <- atom(:alias) do
        %{node_id: node_id, status: status, pid: pid, name: name}
      end

    check all members <-
                uniq_list_of(member,
                  min_length: 2,
                  uniq_fun: fn %{node_id: node_id} -> node_id end
                ),
              identifier <- string(:alphanumeric) do
      partition_a = members

      partition_b =
        members
        |> Enum.map(fn
          %{status: :alive} = member ->
            %{member | status: :dead}

          %{status: :dead} = member ->
            %{member | status: :alive}

          node_spec ->
            node_spec
        end)

      chosen_a = Horde.UniformQuorumDistribution.choose_node(identifier, partition_a)

      chosen_b = Horde.UniformQuorumDistribution.choose_node(identifier, partition_b)

      partitions_succeeded =
        [chosen_a, chosen_b]
        |> Enum.count(fn
          {:ok, _} -> 1
          {:error, _} -> false
        end)

      Enum.all?(members, fn
        %{status: :shutting_down} -> true
        _ -> false
      end)
      |> if do
        assert 0 == partitions_succeeded
      else
        assert 1 == partitions_succeeded
      end
    end
  end
end
