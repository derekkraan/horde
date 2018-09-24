defmodule RegistryTest do
  use ExUnit.Case, async: false
  doctest Horde.Registry

  describe ".join_hordes/2" do
    test "two hordes can join each other" do
      {:ok, _horde_1} = Horde.Registry.start_link(name: :horde_1_a)
      {:ok, _horde_2} = Horde.Registry.start_link(name: :horde_2_a)
      Horde.Cluster.join_hordes(:horde_1_a, :horde_2_a)
      Process.sleep(50)
      {:ok, members} = Horde.Cluster.members(:horde_2_a)
      assert 2 = Enum.count(members)
    end

    test "three hordes can join in one giant horde" do
      {:ok, _horde_1} = Horde.Registry.start_link(name: :horde_1_b)
      {:ok, _horde_2} = Horde.Registry.start_link(name: :horde_2_b)
      {:ok, _horde_3} = Horde.Registry.start_link(name: :horde_3_b)
      Horde.Cluster.join_hordes(:horde_1_b, :horde_2_b)
      Horde.Cluster.join_hordes(:horde_2_b, :horde_3_b)
      Process.sleep(100)
      {:ok, members} = Horde.Cluster.members(:horde_2_b)
      assert 3 = Enum.count(members)
    end

    test "25 hordes can join in one gargantuan horde" do
      last_horde =
        1..25
        |> Enum.reduce(nil, fn x, last_horde ->
          {:ok, _horde} = Horde.Registry.start_link(name: :"horde_#{x}_c")
          if last_horde, do: Horde.Cluster.join_hordes(:"horde_#{x}_c", last_horde)
          :"horde_#{x}_c"
        end)

      Process.sleep(3000)
      {:ok, members} = Horde.Cluster.members(last_horde)
      assert 25 = Enum.count(members)
    end
  end

  describe ".register/3" do
    test "cannot register 2 processes under same name with same horde" do
      horde = :horde_1_d
      {:ok, _horde_1} = Horde.Registry.start_link(name: horde)
      {:ok, horde: horde}

      pid1 = spawn(fn -> Process.sleep(50) end)
      pid2 = spawn(fn -> Process.sleep(50) end)
      Horde.Registry.register(horde, :highlander, pid1)
      Horde.Registry.register(horde, :highlander, pid2)
      Process.sleep(20)
      processes = Horde.Registry.processes(horde)
      assert [:highlander] = Map.keys(processes)
    end

    test "cannot register 2 processes under same name with different hordes" do
      horde = :horde_1_e
      {:ok, _horde_1} = Horde.Registry.start_link(name: horde)

      horde_2 = :horde_2_e
      {:ok, _} = Horde.Registry.start_link(name: horde_2)
      Horde.Cluster.join_hordes(horde, horde_2)
      pid1 = spawn(fn -> Process.sleep(30) end)
      pid2 = spawn(fn -> Process.sleep(30) end)
      Horde.Registry.register(horde, :MacLeod, pid1)
      Horde.Registry.register(horde_2, :MacLeod, pid2)
      Process.sleep(400)
      processes = Horde.Registry.processes(horde)
      processes_2 = Horde.Registry.processes(horde_2)
      assert 1 = Map.size(processes)
      assert processes == processes_2
    end
  end

  describe "register via callbacks" do
    test "register a name the 'via' way" do
      horde = Horde.Registry.ClusterA
      {:ok, _horde} = Horde.Registry.start_link(name: horde)

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
      {:ok, _horde_1} = Horde.Registry.start_link(name: horde)
      {:ok, _horde_2} = Horde.Registry.start_link(name: horde2)
      Horde.Cluster.join_hordes(horde, horde2)

      pid1 = spawn(fn -> Process.sleep(300) end)
      Horde.Registry.register(horde, :one_day_fly, pid1)
      Process.sleep(200)
      assert %{one_day_fly: {_id}} = Horde.Registry.processes(horde)
      assert %{one_day_fly: {_id}} = Horde.Registry.processes(horde2)
      Horde.Registry.unregister(horde, :one_day_fly)
      Process.sleep(500)
      assert %{} == Horde.Registry.processes(horde)
      assert %{} == Horde.Registry.processes(horde2)
    end
  end

  describe ".leave_horde/2" do
    test "can leave horde" do
      {:ok, _horde_1} = Horde.Registry.start_link(name: :horde_1_g)
      {:ok, _horde_2} = Horde.Registry.start_link(name: :horde_2_g)
      {:ok, _horde_3} = Horde.Registry.start_link(name: :horde_3_g)
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
      {:ok, _horde} = Horde.Registry.start_link(name: horde)
      carmen = spawn(fn -> Process.sleep(300) end)
      Horde.Registry.register(horde, :carmen, carmen)
      Process.sleep(100)

      assert carmen == Horde.Registry.lookup(horde, :carmen)
    end

    test "existing processes with via tuple" do
      horde = Horde.Registry.ClusterC
      {:ok, _horde} = Horde.Registry.start_link(name: horde)
      carmen = spawn(fn -> Process.sleep(300) end)
      Horde.Registry.register(horde, :carmen, carmen)
      Process.sleep(100)
      name = {:via, Horde.Registry, {horde, :carmen}}
      assert carmen == Horde.Registry.lookup(name)
    end
  end

  describe "sending messages" do
    test "sending message to non-existing process" do
      horde = Horde.Registry.ClusterD
      {:ok, _horde} = Horde.Registry.start_link(name: horde)
      carmen = spawn(fn -> Process.sleep(300) end)
      Horde.Registry.register(horde, :carmen, carmen)
      Process.sleep(20)

      assert_raise ArgumentError, fn ->
        Horde.Registry.send({horde, :santiago}, "Where are you?")
      end
    end

    test "sending message to non-existing horde" do
      horde = Horde.Registry.ClusterE
      {:ok, _horde} = Horde.Registry.start_link(name: horde)
      carmen = spawn(fn -> Process.sleep(300) end)
      Horde.Registry.register(horde, :carmen, carmen)
      Process.sleep(20)

      assert {:normal, {GenServer, :call, _}} =
               catch_exit(Horde.Registry.send({carmen, :santiago}, "Where are you?"))
    end

    test "sending message to existing process" do
      horde = Horde.Registry.ClusterF
      {:ok, _horde} = Horde.Registry.start_link(name: horde)
      carmen = spawn(fn -> Process.sleep(300) end)
      Horde.Registry.register(horde, :carmen, carmen)
      Process.sleep(20)

      assert "Where are you?" = Horde.Registry.send({horde, :carmen}, "Where are you?")
    end
  end
end
