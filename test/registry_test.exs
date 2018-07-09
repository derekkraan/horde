defmodule RegistryTest do
  use ExUnit.Case, async: false
  doctest Horde.Registry

  describe ".join_hordes/2" do
    test "two hordes can join each other" do
      {:ok, horde_1} = Horde.Registry.start_link(name: :horde_1_a)
      {:ok, horde_2} = Horde.Registry.start_link(name: :horde_2_a)
      Horde.Cluster.join_hordes(horde_1, horde_2)
      Process.sleep(50)
      {:ok, members} = Horde.Cluster.members(horde_2)
      assert 2 = Enum.count(members)
    end

    test "three hordes can join in one giant horde" do
      {:ok, horde_1} = Horde.Registry.start_link(name: :horde_1_b)
      {:ok, horde_2} = Horde.Registry.start_link(name: :horde_2_b)
      {:ok, horde_3} = Horde.Registry.start_link(name: :horde_3_b)
      Horde.Cluster.join_hordes(horde_1, horde_2)
      Horde.Cluster.join_hordes(horde_2, horde_3)
      Process.sleep(100)
      {:ok, members} = Horde.Cluster.members(horde_2)
      assert 3 = Enum.count(members)
    end

    test "25 hordes can join in one gargantuan horde" do
      last_horde =
        1..25
        |> Enum.reduce(nil, fn x, last_horde ->
          {:ok, horde} = Horde.Registry.start_link(name: :"horde_#{x}_c")
          if last_horde, do: Horde.Cluster.join_hordes(horde, last_horde)
          horde
        end)

      Process.sleep(3000)
      {:ok, members} = Horde.Cluster.members(last_horde)
      assert 25 = Enum.count(members)
    end
  end

  describe ".register/3" do
    setup do
      {:ok, horde_1} = Horde.Registry.start_link(name: :horde_1_d)
      {:ok, horde: horde_1}
    end

    test "cannot register 2 processes under same name with same horde", %{horde: horde} do
      pid1 = spawn(fn -> Process.sleep(50) end)
      pid2 = spawn(fn -> Process.sleep(50) end)
      Horde.Registry.register(horde, :highlander, pid1)
      Horde.Registry.register(horde, :highlander, pid2)
      Process.sleep(20)
      processes = Horde.Registry.processes(horde)
      assert [:highlander] = Map.keys(processes)
    end

    test "cannot register 2 processes under same name with different hordes", %{horde: horde} do
      {:ok, horde_2} = Horde.Registry.start_link(name: :horde_2_e)
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
    setup do
      {:ok, horde} = Horde.Registry.start_link(name: Horde.Registry.ClusterA)
      {:ok, horde: horde}
    end

    test "register a name the 'via' way", %{horde: horde} do
      name = {:via, Horde.Registry, {Horde.Registry.ClusterA, "precious"}}
      {:ok, apid} = Agent.start_link(fn -> 0 end, name: name)
      Process.sleep(10)
      assert 0 = Agent.get(name, & &1)
      assert apid == Horde.Registry.lookup(horde, "precious")
    end
  end

  describe ".unregister/2" do
    setup do
      {:ok, horde_1} = Horde.Registry.start_link(name: :horde_1_f)
      {:ok, horde_2} = Horde.Registry.start_link(name: :horde_2_f)
      Horde.Cluster.join_hordes(horde_1, horde_2)
      {:ok, horde: horde_1, horde_2: horde_2}
    end

    test "can unregister processes", %{horde: horde, horde_2: horde_2} do
      pid1 = spawn(fn -> Process.sleep(300) end)
      Horde.Registry.register(horde, :one_day_fly, pid1)
      Process.sleep(200)
      assert %{one_day_fly: {_id}} = Horde.Registry.processes(horde)
      assert %{one_day_fly: {_id}} = Horde.Registry.processes(horde_2)
      Horde.Registry.unregister(horde, :one_day_fly)
      Process.sleep(500)
      assert %{} == Horde.Registry.processes(horde)
      assert %{} == Horde.Registry.processes(horde_2)
    end
  end

  describe ".leave_horde/2" do
    test "can leave horde" do
      {:ok, horde_1} = Horde.Registry.start_link(name: :horde_1_g)
      {:ok, horde_2} = Horde.Registry.start_link(name: :horde_2_g)
      {:ok, horde_3} = Horde.Registry.start_link(name: :horde_3_g)
      Horde.Cluster.join_hordes(horde_1, horde_2)
      Horde.Cluster.join_hordes(horde_2, horde_3)
      Process.sleep(200)
      {:ok, members} = Horde.Cluster.members(horde_2)
      assert 3 = Enum.count(members)
      :ok = Horde.Registry.stop(horde_2)
      Process.sleep(20)
      {:ok, members} = Horde.Cluster.members(horde_1)
      assert 2 = Enum.count(members)
    end
  end

  describe "lookup" do
    setup do
      {:ok, horde} = Horde.Registry.start_link(name: Horde.Registry.ClusterB)
      pid1 = spawn(fn -> Process.sleep(300) end)
      Horde.Registry.register(horde, :carmen, pid1)
      Process.sleep(100)
      {:ok, horde: horde, carmen: pid1}
    end

    test "existing process with lookup/2", %{horde: horde, carmen: carmen} do
      assert carmen == Horde.Registry.lookup(horde, :carmen)
    end

    test "existing process the 'via' way", %{carmen: carmen} do
      name = {:via, Horde.Registry, {Horde.Registry.ClusterB, :carmen}}
      assert carmen == Horde.Registry.lookup(name)
    end
  end

  describe "sending messages" do
    setup do
      {:ok, horde} = Horde.Registry.start_link(name: Horde.Registry.ClusterC)
      pid1 = spawn(fn -> Process.sleep(300) end)
      Horde.Registry.register(horde, :carmen, pid1)
      Process.sleep(20)
      {:ok, horde: horde, carmen: pid1}
    end

    test "sending message to non-existing process", %{horde: horde} do
      assert_raise ArgumentError, fn ->
        Horde.Registry.send({horde, :santiago}, "Where are you?")
      end
    end

    test "sending message to non-existing horde", %{carmen: pid} do
      assert {:normal, {GenServer, :call, _}} =
               catch_exit(Horde.Registry.send({pid, :santiago}, "Where are you?"))
    end

    test "sending message to existing process", %{horde: horde} do
      assert "Where are you?" = Horde.Registry.send({horde, :carmen}, "Where are you?")
    end
  end
end
