defmodule HordeTest do
  use ExUnit.Case
  doctest Horde

  describe ".join_hordes/2" do
    test "two hordes can join each other" do
      {:ok, horde_1} = GenServer.start_link(Horde, :horde_1)
      {:ok, horde_2} = GenServer.start_link(Horde, :horde_2)
      Horde.join_hordes(horde_1, horde_2)
      Process.sleep(10)
      {:ok, members} = Horde.members(horde_2)
      assert [:horde_1, :horde_2] = Map.keys(members)
    end

    test "three hordes can join in one giant horde" do
      {:ok, horde_1} = GenServer.start_link(Horde, :horde_1)
      {:ok, horde_2} = GenServer.start_link(Horde, :horde_2)
      {:ok, horde_3} = GenServer.start_link(Horde, :horde_3)
      Horde.join_hordes(horde_1, horde_2)
      Horde.join_hordes(horde_2, horde_3)
      Process.sleep(10)
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
end
