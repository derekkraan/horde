defmodule RoutingTest do
  use ExUnit.Case
  doctest Routing

  test "greets the world" do
    assert Routing.hello() == :world
  end
end
