defmodule HelloWorld.SayHello do
  use GenServer

  def child_spec(opts) do
    name = Keyword.get(opts, :name, __MODULE__)

    %{id: "#{__MODULE__}_#{name}", start: {__MODULE__, :start_link, [name]}, shutdown: 10_000}
  end

  def start_link(name) do
    GenServer.start_link(__MODULE__, [], name: via_tuple(name))
  end

  def how_many?(name \\ __MODULE__) do
    GenServer.call(via_tuple(name), :how_many?)
  end

  def init(args) do
    send(self(), :say_hello)

    {:ok, 0}
  end

  def handle_info(:say_hello, counter) do
    IO.puts("HELLO from node #{inspect(Node.self())}")
    Process.send_after(self(), :say_hello, 5000)
    {:noreply, counter + 1}
  end

  def handle_call(:how_many?, _from, counter) do
    {:reply, counter, counter}
  end

  def via_tuple(name), do: {:via, Horde.Registry, {HelloWorld.HelloRegistry, name}}
end
