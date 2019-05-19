defmodule Counter.Worker do
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

  def init(_args) do
    {:ok, 0}
  end

  def handle_cast(:increment, count) do
    {:noreply, count + 1}
  end

  def handle_call(:value, _from, count) do
    {:reply, count, count}
  end

  def via_tuple(name), do: {:via, Horde.Registry, {Counter.Registry, name}}
end
