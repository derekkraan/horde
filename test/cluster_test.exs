defmodule ClusterTest do
  use ExUnit.Case, async: true

  describe ".join_hordes/2" do
    test "returns true when registries joined" do
      {:ok, reg1} = Horde.Registry.start_link(name: :reg1)
      {:ok, reg2} = Horde.Registry.start_link(name: :reg2)
      assert true = Horde.Cluster.join_hordes(reg1, reg2)
    end

    test "returns true when supervisors joined" do
      {:ok, _} = Horde.Supervisor.start_link(name: :sup1, strategy: :one_for_one)
      {:ok, _} = Horde.Supervisor.start_link(name: :sup2, strategy: :one_for_one)
      assert true = Horde.Cluster.join_hordes(:sup1, :sup2)
    end

    test "returns false when other registry doesn't exist" do
      {:ok, reg3} = Horde.Registry.start_link(name: :reg3)
      assert false == Horde.Cluster.join_hordes(reg3, :doesnt_exist, 100)
    end

    test "returns false when other supervisor doesn't exist" do
      {:ok, _} = Horde.Supervisor.start_link(name: :sup3, strategy: :one_for_one)
      assert false == Horde.Cluster.join_hordes(:sup3, :doesnt_exist, 100)
    end
  end
end
