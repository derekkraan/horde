defmodule UniformDistributionTest do
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

    check all members <- list_of(member),
              own_node_id <- integer(),
              identifier <- string(:alphanumeric) do
      members = [{own_node_id, {:alive, %{name: :name, pid: :pid}}} | members]
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
