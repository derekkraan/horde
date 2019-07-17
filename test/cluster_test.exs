defmodule ClusterTest do
  use ExUnit.Case, async: true

  describe "members option" do
    test "can join registry by specifying members in init" do
      {:ok, _} =
        Horde.Registry.start_link(
          name: :reg4,
          keys: :unique,
          members: [:reg4, :reg5],
          delta_crdt_options: [sync_interval: 10]
        )

      {:ok, _} =
        Horde.Registry.start_link(
          name: :reg5,
          keys: :unique,
          members: [:reg4, :reg5],
          delta_crdt_options: [sync_interval: 10]
        )

      {:ok, members} = Horde.Cluster.members(:reg4)
      assert 2 = Enum.count(members)
    end

    test "can join supervisor by specifying members in init" do
      {:ok, _} =
        Horde.Supervisor.start_link(
          name: :sup4,
          strategy: :one_for_one,
          members: [:sup4, :sup5],
          delta_crdt_options: [sync_interval: 10]
        )

      {:ok, _} =
        Horde.Supervisor.start_link(
          name: :sup5,
          strategy: :one_for_one,
          members: [:sup4, :sup5],
          delta_crdt_options: [sync_interval: 10]
        )

      {:ok, members} = Horde.Cluster.members(:sup4)
      assert 2 = Enum.count(members)
    end
  end

  describe ".members/1" do
    test "Registry returns same thing after setting members twice" do
      {:ok, _reg1} =
        Horde.Registry.start_link(
          name: :reg0,
          keys: :unique,
          delta_crdt_options: [sync_interval: 10]
        )

      assert :ok = Horde.Cluster.set_members(:reg0, [:reg00, :reg0])
      assert {:ok, [{:reg0, node()}, {:reg00, node()}]} == Horde.Cluster.members(:reg0)
      assert :ok = Horde.Cluster.set_members(:reg0, [:reg00, :reg0])
      assert {:ok, [{:reg0, node()}, {:reg00, node()}]} == Horde.Cluster.members(:reg0)
    end

    test "Supervisor returns same thing after setting members twice" do
      {:ok, _reg1} =
        Horde.Supervisor.start_link(
          name: :sup0,
          strategy: :one_for_one,
          delta_crdt_options: [sync_interval: 10]
        )

      assert :ok = Horde.Cluster.set_members(:sup0, [:sup00, :sup0])
      assert {:ok, [{:sup0, node()}, {:sup00, node()}]} == Horde.Cluster.members(:sup0)
      assert :ok = Horde.Cluster.set_members(:sup0, [:sup00, :sup0])
      assert {:ok, [{:sup0, node()}, {:sup00, node()}]} == Horde.Cluster.members(:sup0)
    end
  end

  describe ".set_members/2" do
    test "returns true when registries joined" do
      {:ok, _reg1} =
        Horde.Registry.start_link(
          name: :reg1,
          keys: :unique,
          delta_crdt_options: [sync_interval: 10]
        )

      {:ok, _reg2} =
        Horde.Registry.start_link(
          name: :reg2,
          keys: :unique,
          delta_crdt_options: [sync_interval: 10]
        )

      assert :ok = Horde.Cluster.set_members(:reg1, [:reg1, :reg2])
    end

    test "returns true when supervisors joined" do
      {:ok, _} =
        Horde.Supervisor.start_link(
          name: :sup1,
          strategy: :one_for_one,
          delta_crdt_options: [sync_interval: 10]
        )

      {:ok, _} =
        Horde.Supervisor.start_link(
          name: :sup2,
          strategy: :one_for_one,
          delta_crdt_options: [sync_interval: 10]
        )

      assert :ok = Horde.Cluster.set_members(:sup1, [:sup1, :sup2])
    end

    test "returns true when other registry doesn't exist" do
      {:ok, _reg3} =
        Horde.Registry.start_link(
          name: :reg3,
          keys: :unique,
          delta_crdt_options: [sync_interval: 10]
        )

      assert :ok = Horde.Cluster.set_members(:reg3, [:reg3, :doesnt_exist], 100)
    end

    test "returns true when other supervisor doesn't exist" do
      {:ok, _} =
        Horde.Supervisor.start_link(
          name: :sup3,
          strategy: :one_for_one,
          delta_crdt_options: [sync_interval: 10]
        )

      assert :ok = Horde.Cluster.set_members(:sup3, [:sup3, :doesnt_exist], 100)
    end

    test "can join and unjoin supervisor with set_members" do
      {:ok, _} =
        Horde.Supervisor.start_link(
          name: :sup6,
          strategy: :one_for_one,
          delta_crdt_options: [sync_interval: 10]
        )

      {:ok, _} =
        Horde.Supervisor.start_link(
          name: :sup7,
          strategy: :one_for_one,
          delta_crdt_options: [sync_interval: 10]
        )

      assert :ok = Horde.Cluster.set_members(:sup6, [:sup6, :sup7])

      {:ok, members} = Horde.Cluster.members(:sup6)
      assert 2 = Enum.count(members)

      Process.sleep(50)

      assert :ok = Horde.Cluster.set_members(:sup6, [:sup6])

      {:ok, [sup6: _nonode]} = Horde.Cluster.members(:sup6)
    end

    test "can join and unjoin registry with set_members" do
      {:ok, _} =
        Horde.Registry.start_link(
          name: :reg6,
          keys: :unique,
          delta_crdt_options: [sync_interval: 10]
        )

      {:ok, _} =
        Horde.Registry.start_link(
          name: :reg7,
          keys: :unique,
          delta_crdt_options: [sync_interval: 10]
        )

      assert :ok = Horde.Cluster.set_members(:reg6, [:reg6, :reg7])

      Process.sleep(200)

      {:ok, members} = Horde.Cluster.members(:reg6)
      assert 2 = Enum.count(members)

      assert :ok = Horde.Cluster.set_members(:reg6, [:reg4])

      Process.sleep(200)

      {:ok, members} = Horde.Cluster.members(:reg6)

      assert 1 = Enum.count(members)
    end

    test "supervisor can start child" do
      {:ok, _} = start_supervised({Horde.Supervisor, [name: :sup, strategy: :one_for_one]})
      assert :ok = Horde.Cluster.set_members(:sup, [:sup])
      {:ok, child_pid} = Supervisor.start_child(:sup, {Task, fn -> :ok end})
      assert is_pid(child_pid)
    end
  end
end
