defmodule TestRegistry1 do
  use Horde.Registry

  def init(options) do
    {:ok, Keyword.put(options, :members, [:init_test_1, :init_test_2])}
  end
end

defmodule TestRegistry2 do
  use Horde.Registry

  def init(options) do
    {:ok, Keyword.put(options, :members, [:init_test_1, :init_test_2])}
  end
end
