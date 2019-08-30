defmodule TestRegistry1 do
  use Horde.Registry

  def start_link(init_arg, opts \\ []) do
    Horde.Registry.start_link(__MODULE__, init_arg, opts)
  end

  @impl true
  def init(init_arg) do
    [keys: :unique, members: [:init_test_1, :init_test_2]]
    |> Keyword.merge(init_arg)
    |> Horde.Registry.init()
  end
end

defmodule TestRegistry2 do
  use Horde.Registry

  def start_link(init_arg, opts \\ []) do
    Horde.Registry.start_link(__MODULE__, init_arg, opts)
  end

  @impl true
  def init(init_arg) do
    [keys: :unique, members: [:init_test_1, :init_test_2]]
    |> Keyword.merge(init_arg)
    |> Horde.Registry.init()
  end
end

defmodule TestRegistry3 do
  use Horde.Registry

  def start_link(init_arg, opts \\ []) do
    opts = Keyword.put_new(opts, :name, __MODULE__)
    Horde.Registry.start_link(__MODULE__, init_arg, opts)
  end

  @impl true
  def init(init_arg) do
    [keys: :unique, members: [:init_test_1, :init_test_2]]
    |> Keyword.merge(init_arg)
    |> Horde.Registry.init()
  end
end

defmodule TestRegistry4 do
  use Horde.Registry,
    restart: :transient,
    # value provided to differ from default :supervisor option
    type: :worker

  def start_link(init_arg, opts \\ []) do
    opts = Keyword.put_new(opts, :name, __MODULE__)
    Horde.Registry.start_link(__MODULE__, init_arg, opts)
  end

  @impl true
  def init(init_arg) do
    [keys: :unique, members: [:init_test_1, :init_test_2]]
    |> Keyword.merge(init_arg)
    |> Horde.Registry.init()
  end
end
