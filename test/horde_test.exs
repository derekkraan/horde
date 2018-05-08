defmodule HordeTest do
  use ExUnit.Case
  doctest Horde

  test "greets the world" do
    assert Horde.hello() == :world
  end
end
