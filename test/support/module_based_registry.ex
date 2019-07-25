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

defmodule TestRegistry3 do
  use Horde.Registry
  @base_opts [keys: :unique, name: __MODULE__]

  @impl true
  def init(options) do
    {:ok, Keyword.put(options, :members, [:init_test_1, :init_test_2])}
  end

  @impl true
  def child_spec(args) do
    %{
      id: args[:custom_id],
      start: {__MODULE__, :start_link, [Keyword.merge(@base_opts, args)]},
      restart: :transient,
      type: :supervisor
    }
  end
end

defmodule TestRegistry4 do
  use Horde.Registry,
    restart: :transient,
    # value provided to differ from default :supervisor option
    type: :worker

  @base_opts [keys: :unique, name: __MODULE__]

  @impl true
  def init(options) do
    {:ok, Keyword.put(options, :members, [:init_test_1, :init_test_2])}
  end

  @impl true
  def child_spec(args) do
    args
    |> super
    |> Map.merge(%{
      start: {__MODULE__, :start_link, [Keyword.merge(@base_opts, args)]}
    })
  end
end
