defmodule TestAppTest do
  use ExUnit.Case
  doctest TestApp

  test "greets the world" do
    assert TestApp.hello() == :world
  end
end
