defmodule HelloWorld.SayHello do
  use GenServer
  require Logger

  def child_spec(opts) do
    name = Keyword.get(opts, :name, __MODULE__)

    %{
      id: "#{__MODULE__}_#{name}",
      start: {__MODULE__, :start_link, [name]},
      shutdown: 10_000,
      restart: :permanent
    }
  end

  def start_link(name) do
    GenServer.start_link(__MODULE__, [], name: via_tuple(name))
  end

  def how_many?(name \\ __MODULE__) do
    GenServer.call(via_tuple(name), :how_many?)
  end

  def init(_args) do
    send(self(), :say_hello)

    {:ok, get_global_counter()}
  end

  def handle_info(:say_hello, counter) do
    Logger.info("HELLO from node #{inspect(Node.self())}")
    Process.send_after(self(), :say_hello, 5000)

    {:noreply, put_global_counter(counter + 1)}
  end

  def handle_call(:how_many?, _from, counter) do
    {:reply, counter, counter}
  end

  defp get_global_counter() do
    case Horde.Registry.meta(HelloWorld.HelloRegistry, "count") do
      {:ok, count} ->
        count

      :error ->
        put_global_counter(0)
        get_global_counter()
    end
  end

  defp put_global_counter(counter_value) do
    :ok = Horde.Registry.put_meta(HelloWorld.HelloRegistry, "count", counter_value)
    counter_value
  end

  def via_tuple(name), do: {:via, Horde.Registry, {HelloWorld.HelloRegistry, name}}
end
