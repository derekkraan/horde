defmodule HordeTest do
  use ExUnit.Case
  doctest Horde

  test "two hordes can join each other" do
    {:ok, horde_1} = Horde.start_link(:horde_1)
    {:ok, horde_2} = Horde.start_link(:horde_2)
    Horde.join_hordes(horde_1, horde_2)
    Process.sleep(10)
    {:ok, members} = Horde.members(horde_2)
    assert [:horde_1, :horde_2] = Map.keys(members)
  end

  test "three hordes can join in one giant horde" do
    {:ok, horde_1} = Horde.start_link(:horde_1)
    {:ok, horde_2} = Horde.start_link(:horde_2)
    {:ok, horde_3} = Horde.start_link(:horde_3)
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
        {:ok, horde} = Horde.start_link(:"horde_#{x}")
        if last_horde, do: Horde.join_hordes(horde, last_horde)
        horde
      end)

    Process.sleep(1000)
    {:ok, members} = Horde.members(last_horde)
    assert 25 = Enum.count(members)
  end
end
