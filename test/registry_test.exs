defmodule RegistryTest do
  use ExUnit.Case, async: false
  doctest Horde.Registry

  describe ".start_link/1" do
    test "only keys: :unique is allowed" do
      assert_raise ArgumentError, fn ->
        Horde.Registry.start_link(name: :horde_not_unique, keys: :duplicate)
      end
    end
  end

  describe ".join_hordes/2" do
    test "two hordes can join each other" do
      {:ok, _horde_1} = Horde.Registry.start_link(name: :horde_1_a, keys: :unique)
      {:ok, _horde_2} = Horde.Registry.start_link(name: :horde_2_a, keys: :unique)
      Horde.Cluster.join_hordes(:horde_1_a, :horde_2_a)
      Process.sleep(50)
      {:ok, members} = Horde.Cluster.members(:horde_2_a)
      assert 2 = Enum.count(members)
    end

    test "three hordes can join in one giant horde" do
      {:ok, _horde_1} = Horde.Registry.start_link(name: :horde_1_b, keys: :unique)
      {:ok, _horde_2} = Horde.Registry.start_link(name: :horde_2_b, keys: :unique)
      {:ok, _horde_3} = Horde.Registry.start_link(name: :horde_3_b, keys: :unique)
      Horde.Cluster.join_hordes(:horde_1_b, :horde_2_b)
      Horde.Cluster.join_hordes(:horde_2_b, :horde_3_b)
      Process.sleep(100)
      {:ok, members} = Horde.Cluster.members(:horde_2_b)
      assert 3 = Enum.count(members)
    end
  end

  describe ".register/3" do
    test "cannot register 2 processes under same name with same horde" do
      horde = :horde_1_d
      {:ok, _horde_1} = Horde.Registry.start_link(name: horde, keys: :unique)
      {:ok, horde: horde}

      Horde.Registry.register(horde, :highlander, "val")
      Horde.Registry.register(horde, :highlander, "val")
      processes = Horde.Registry.processes(horde)
      assert [:highlander] = Map.keys(processes)
    end

    test "cannot register 2 processes under same name with different hordes" do
      horde = :horde_1_e
      {:ok, _horde_1} = Horde.Registry.start_link(name: horde, keys: :unique)

      horde_2 = :horde_2_e
      {:ok, _} = Horde.Registry.start_link(name: horde_2, keys: :unique)
      Horde.Cluster.join_hordes(horde, horde_2)
      Horde.Registry.register(horde, :MacLeod, "val1")
      Horde.Registry.register(horde_2, :MacLeod, "val2")
      Process.sleep(200)
      processes = Horde.Registry.processes(horde)
      processes_2 = Horde.Registry.processes(horde_2)
      assert 1 = Map.size(processes)
      assert processes == processes_2
    end
  end

  describe ".keys/2" do
    test "empty list if not registered" do
      registry = Horde.Registry.Cluster0
      {:ok, _horde} = Horde.Registry.start_link(name: registry, keys: :unique)
      assert [] = Horde.Registry.keys(registry, self())
    end

    test "registered keys are returned" do
      registry = Horde.Registry.Cluster1
      {:ok, _horde} = Horde.Registry.start_link(name: registry, keys: :unique)
      registry2 = Horde.Registry.Cluster2
      {:ok, _horde} = Horde.Registry.start_link(name: registry2, keys: :unique)
      Horde.Cluster.join_hordes(registry, registry2)

      Horde.Registry.register(registry, "foo", :value)
      Horde.Registry.register(registry2, "bar", :value)

      Process.sleep(200)

      assert ["foo", "bar"] = Horde.Registry.keys(registry, self())
    end
  end

  describe "register via callbacks" do
    test "register a name the 'via' way" do
      horde = Horde.Registry.ClusterA
      {:ok, _horde} = Horde.Registry.start_link(name: horde, keys: :unique)

      name = {:via, Horde.Registry, {horde, "precious"}}
      {:ok, apid} = Agent.start_link(fn -> 0 end, name: name)
      Process.sleep(10)
      assert 0 = Agent.get(name, & &1)
      assert apid == Horde.Registry.lookup(horde, "precious")
    end
  end

  describe ".unregister/2" do
    test "can unregister processes" do
      horde = :horde_1_f
      horde2 = :horde_2_f
      {:ok, _horde_1} = Horde.Registry.start_link(name: horde, keys: :unique)
      {:ok, _horde_2} = Horde.Registry.start_link(name: horde2, keys: :unique)
      Horde.Cluster.join_hordes(horde, horde2)

      Horde.Registry.register(horde, :one_day_fly, "value")
      assert %{one_day_fly: _id} = Horde.Registry.processes(horde)
      Process.sleep(200)
      assert %{one_day_fly: _id} = Horde.Registry.processes(horde2)

      Horde.Registry.unregister(horde, :one_day_fly)
      assert %{} == Horde.Registry.processes(horde)
      Process.sleep(200)
      assert %{} == Horde.Registry.processes(horde2)
    end
  end

  describe ".leave_horde/2" do
    test "can leave horde" do
      {:ok, _horde_1} = Horde.Registry.start_link(name: :horde_1_g, keys: :unique)
      {:ok, _horde_2} = Horde.Registry.start_link(name: :horde_2_g, keys: :unique)
      {:ok, _horde_3} = Horde.Registry.start_link(name: :horde_3_g, keys: :unique)
      Horde.Cluster.join_hordes(:horde_1_g, :horde_2_g)
      Horde.Cluster.join_hordes(:horde_2_g, :horde_3_g)
      Process.sleep(200)
      {:ok, members} = Horde.Cluster.members(:horde_2_g)
      assert 3 = Enum.count(members)
      :ok = Horde.Registry.stop(:horde_2_g)
      Process.sleep(20)
      {:ok, members} = Horde.Cluster.members(:horde_1_g)
      assert 2 = Enum.count(members)
    end
  end

  describe "lookup" do
    test "existing process with lookup/2" do
      horde = Horde.Registry.ClusterB
      {:ok, _horde} = Horde.Registry.start_link(name: horde, keys: :unique)

      Horde.Registry.register(horde, :carmen, "foo")

      assert self() == Horde.Registry.lookup(horde, :carmen)
    end

    test "existing processes with via tuple" do
      horde = Horde.Registry.ClusterC
      {:ok, _horde} = Horde.Registry.start_link(name: horde, keys: :unique)

      Horde.Registry.register(horde, :carmen, "bar")

      name = {:via, Horde.Registry, {horde, :carmen}}
      assert self() == Horde.Registry.lookup(name)
    end
  end

  describe "sending messages" do
    test "sending message to non-existing process" do
      horde = Horde.Registry.ClusterD
      {:ok, _horde} = Horde.Registry.start_link(name: horde, keys: :unique)
      Horde.Registry.register(horde, :carmen, "carmen")

      assert_raise ArgumentError, fn ->
        Horde.Registry.send({horde, :santiago}, "Where are you?")
      end
    end

    test "sending message to non-existing horde" do
      horde = Horde.Registry.ClusterE
      {:ok, _horde} = Horde.Registry.start_link(name: horde, keys: :unique)

      carmen =
        spawn(fn ->
          Horde.Registry.register(horde, :carmen, "carmen")
          Process.sleep(300)
        end)

      Process.sleep(20)

      assert {:normal, {GenServer, :call, _}} =
               catch_exit(Horde.Registry.send({carmen, :santiago}, "Where are you?"))
    end

    test "sending message to existing process" do
      horde = Horde.Registry.ClusterF
      {:ok, _horde} = Horde.Registry.start_link(name: horde, keys: :unique)

      carmen =
        spawn(fn ->
          Horde.Registry.register(horde, :carmen, "carmen")
          Process.sleep(300)
        end)

      Process.sleep(20)

      assert "Where are you?" = Horde.Registry.send({horde, :carmen}, "Where are you?")
    end
  end

  describe ".meta/2 and .put_meta/3" do
    test "can set meta in start_link/3" do
      registry = Horde.Registry.ClusterH

      {:ok, _horde} =
        Horde.Registry.start_link(name: registry, keys: :unique, meta: [meta_key: :meta_value])

      assert {:ok, :meta_value} = Horde.Registry.meta(registry, :meta_key)
    end

    test "can put and get metadata" do
      registry = Horde.Registry.ClusterG
      {:ok, _horde} = Horde.Registry.start_link(name: registry, keys: :unique)
      :ok = Horde.Registry.put_meta(registry, :custom_key, "custom_value")

      assert {:ok, "custom_value"} = Horde.Registry.meta(registry, :custom_key)
    end

    test "meta/2 returns :error when no entry present" do
      registry = Horde.Registry.ClusterI
      {:ok, _horde} = Horde.Registry.start_link(name: registry, keys: :unique)
      :ok = Horde.Registry.put_meta(registry, :custom_key, "custom_value")

      assert :error = Horde.Registry.meta(registry, :non_existant)
    end
  end
end
