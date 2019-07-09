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

defmodule TestSupervisor3 do
  use Horde.Supervisor

  def init(options) do
    {:ok, Keyword.put(options, :members, [:init_sup_test_3, :init_sup_test_3])}
  end

  def child_spec(args) do
    %{
      id: args[:custom_id],
      start: {__MODULE__, :start_link, [args]},
      restart: :transient,
      type: :supervisor
    }
  end
end
