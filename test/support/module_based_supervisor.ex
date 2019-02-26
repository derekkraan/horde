defmodule TestSupervisor1 do
  use Horde.Supervisor

  def init(options) do
    {:ok, Keyword.put(options, :members, [:init_sup_test_1, :init_sup_test_2])}
  end
end

defmodule TestSupervisor2 do
  use Horde.Supervisor

  def init(options) do
    {:ok, Keyword.put(options, :members, [:init_sup_test_1, :init_sup_test_2])}
  end
end
