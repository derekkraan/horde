defmodule HordeTest do
  use ExUnit.Case
  doctest Horde

  describe ".join_hordes/2" do
    test "two hordes can join each other" do
      {:ok, horde_1} = GenServer.start_link(Horde, :horde_1)
      {:ok, horde_2} = GenServer.start_link(Horde, :horde_2)
      Horde.join_hordes(horde_1, horde_2)
      Process.sleep(100)
      {:ok, members} = Horde.members(horde_2)
      assert [:horde_1, :horde_2] = Map.keys(members)
    end

    test "three hordes can join in one giant horde" do
      {:ok, horde_1} = GenServer.start_link(Horde, :horde_1)
      {:ok, horde_2} = GenServer.start_link(Horde, :horde_2)
      {:ok, horde_3} = GenServer.start_link(Horde, :horde_3)
      Horde.join_hordes(horde_1, horde_2)
      Horde.join_hordes(horde_2, horde_3)
      Process.sleep(100)
      {:ok, members} = Horde.members(horde_2)
      assert [:horde_1, :horde_2, :horde_3] = Map.keys(members)
    end

    test "25 hordes can join in one gargantuan horde" do
      last_horde =
        1..25
        |> Enum.reduce(nil, fn x, last_horde ->
          {:ok, horde} = GenServer.start_link(Horde, :"horde_#{x}")
          if last_horde, do: Horde.join_hordes(horde, last_horde)
          horde
        end)

      Process.sleep(1000)
      {:ok, members} = Horde.members(last_horde)
      assert 25 = Enum.count(members)
    end
  end

  describe ".register/3" do
    setup do
      {:ok, horde_1} = GenServer.start_link(Horde, :horde_1)
      {:ok, horde: horde_1}
    end

    test "cannot register 2 processes under same name with same horde", %{horde: horde} do
      pid1 = spawn(fn -> Process.sleep(30) end)
      pid2 = spawn(fn -> Process.sleep(30) end)
      Horde.register(horde, :highlander, pid1)
      Horde.register(horde, :highlander, pid2)
      Process.sleep(10)
      {:ok, processes} = Horde.processes(horde)
      assert [:highlander] = Map.keys(processes)
    end

    test "cannot register 2 processes under same name with different hordes", %{horde: horde} do
      {:ok, horde_2} = GenServer.start_link(Horde, :horde_2)
      Horde.join_hordes(horde, horde_2)
      pid1 = spawn(fn -> Process.sleep(30) end)
      pid2 = spawn(fn -> Process.sleep(30) end)
      Horde.register(horde, :MacLeod, pid1)
      Horde.register(horde_2, :MacLeod, pid2)
      Process.sleep(100)
      {:ok, processes} = Horde.processes(horde)
      {:ok, processes_2} = Horde.processes(horde_2)
      assert 1 = Map.size(processes)
      assert processes == processes_2
    end
  end

  describe "register via callbacks" do
    setup do
      {:ok, horde} = GenServer.start_link(Horde, :horde_1, [name: Horde.Tracker])
      {:ok, horde: horde}
    end

    test "register a name the 'via' way", %{horde: horde} do
      name = {:via, Horde, {Horde.Tracker, "precious"}}
      {:ok, apid} = Agent.start_link(fn -> 0 end, name: name)
      Process.sleep(100)
      assert 0 = Agent.get(name, &(&1))
      assert apid == Horde.lookup(horde, "precious")
    end
  end


  describe ".unregister/2" do
    setup do
      {:ok, horde_1} = GenServer.start_link(Horde, :horde_1)
      {:ok, horde: horde_1}
    end

    test "can unregister processes", %{horde: horde} do
      pid1 = spawn(fn -> Process.sleep(300) end)
      Horde.register(horde, :one_day_fly, pid1)
      Process.sleep(10)
      assert {:ok, %{one_day_fly: {_id}}} = Horde.processes(horde)
      Horde.unregister(horde, :one_day_fly)
      Process.sleep(10)
      assert {:ok, %{}} = Horde.processes(horde)
    end
  end

  describe ".leave_horde/2" do
    test "can leave horde" do
      {:ok, horde_1} = GenServer.start_link(Horde, :horde_1)
      {:ok, horde_2} = GenServer.start_link(Horde, :horde_2)
      {:ok, horde_3} = GenServer.start_link(Horde, :horde_3)
      Horde.join_hordes(horde_1, horde_2)
      Horde.join_hordes(horde_2, horde_3)
      Process.sleep(10)
      {:ok, members} = Horde.members(horde_2)
      assert [:horde_1, :horde_2, :horde_3] = Map.keys(members)
      Horde.leave_hordes(horde_2)
      Process.sleep(10)
      {:ok, members} = Horde.members(horde_1)
      assert [:horde_1, :horde_3] = Map.keys(members)
    end
  end
end
