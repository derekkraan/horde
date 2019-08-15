defmodule TestSupervisor1 do
  use Horde.Supervisor

  def start_link(init_arg, options \\ []) do
    Horde.Supervisor.start_link(__MODULE__, init_arg, options)
  end

  @impl true
  def init(init_arg) do
    [strategy: :one_for_one, members: [:init_sup_test_1, :init_sup_test_2]]
    |> Keyword.merge(init_arg)
    |> Horde.Supervisor.init()
  end
end

defmodule TestSupervisor2 do
  use Horde.Supervisor

  def start_link(init_arg, options \\ []) do
    Horde.Supervisor.start_link(__MODULE__, init_arg, options)
  end

  @impl true
  def init(init_arg) do
    [strategy: :one_for_one, members: [:init_sup_test_1, :init_sup_test_2]]
    |> Keyword.merge(init_arg)
    |> Horde.Supervisor.init()
  end
end

defmodule TestSupervisor3 do
  use Horde.Supervisor

  def start_link(init_arg, options \\ []) do
    Horde.Supervisor.start_link(__MODULE__, init_arg, options)
  end

  @impl true
  def init(init_arg) do
    [strategy: :one_for_one, members: [:init_sup_test_3, :init_sup_test_3]]
    |> Keyword.merge(init_arg)
    |> Horde.Supervisor.init()
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
