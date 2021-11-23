defmodule UniformDistributionTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  property "chooses one of the members" do
    member =
      ExUnitProperties.gen all(
                             node_id <- integer(1..100_000),
                             status <- StreamData.member_of([:alive, :dead, :shutting_down]),
                             name <- binary(),
                             pid <- atom(:alias)
                           ) do
        %{node_id: node_id, status: status, pid: pid, name: "A#{name}"}
      end

    check all(
            members <- list_of(member),
            own_node_id <- integer(),
            identifier <- string(:alphanumeric)
          ) do
      child_spec = %{ id: identifier, start: {identifier}}
      members = [%{node_id: own_node_id, status: :alive, name: :name, pid: :pid} | members]
      choice = Horde.UniformDistribution.choose_node(child_spec, members)

      # it always chooses a node that's alive
      assert {:ok, %{status: :alive} = chosen_member} = choice

      assert Enum.any?(members, fn
               ^chosen_member -> true
               _ -> false
             end)
    end
  end

  property "returns error if no alive nodes are available" do
    member =
      ExUnitProperties.gen all(
                             node_id <- integer(1..100_000),
                             status <- StreamData.member_of([:dead, :shutting_down]),
                             name <- binary(),
                             pid <- atom(:alias)
                           ) do
        %{node_id: node_id, status: status, pid: pid, name: name}
      end

    check all(
            members <- list_of(member),
            identifier <- string(:alphanumeric)
          ) do
      child_spec = %{ id: identifier, start: {identifier}}
      choice = Horde.UniformDistribution.choose_node(child_spec, members)

      assert {:error, :no_alive_nodes} = choice
    end
  end
end
