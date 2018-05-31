defmodule UniformDistributionTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  property "chooses one of the members" do
    member =
      ExUnitProperties.gen all node_id <- integer(),
                               status <- StreamData.member_of([:alive, :dead, :shutting_down]),
                               tuple <- tuple({term(), term(), term()}) do
        {node_id, {status, tuple}}
      end

    check all members <- list_of(member),
              own_node_id <- integer(),
              identifier <- string(:alphanumeric) do
      members = [{own_node_id, {:alive, {}}} | members]
      chosen = Horde.UniformDistribution.choose_node(identifier, members)

      # it always chooses a node that's alive
      assert {_, {:alive, _}} = chosen

      assert Enum.any?(members, fn
               ^chosen -> true
               _ -> false
             end)
    end
  end
end
