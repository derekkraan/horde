defmodule ClusterTest do
  use ExUnit.Case, async: true

  describe ".join_hordes/2" do
    test "returns true when registries joined" do
      {:ok, _reg1} = Horde.Registry.start_link(name: :reg1, keys: :unique)
      {:ok, _reg2} = Horde.Registry.start_link(name: :reg2, keys: :unique)
      assert :ok = Horde.Cluster.set_members(:reg1, [:reg1, :reg2])
    end

    test "returns true when supervisors joined" do
      {:ok, _} = Horde.Supervisor.start_link(name: :sup1, strategy: :one_for_one)
      {:ok, _} = Horde.Supervisor.start_link(name: :sup2, strategy: :one_for_one)
      assert :ok = Horde.Cluster.set_members(:sup1, [:sup1, :sup2])
    end

    test "returns true when other registry doesn't exist" do
      {:ok, _reg3} = Horde.Registry.start_link(name: :reg3, keys: :unique)
      assert :ok = Horde.Cluster.set_members(:reg3, [:reg3, :doesnt_exist], 100)
    end

    test "returns true when other supervisor doesn't exist" do
      {:ok, _} = Horde.Supervisor.start_link(name: :sup3, strategy: :one_for_one)
      assert :ok = Horde.Cluster.set_members(:sup3, [:sup3, :doesnt_exist], 100)
    end
  end
end
