defmodule Dynamic.Entity do
  use GenServer

  def start_link(name, data) do
    GenServer.start_link(__MODULE__, {name, data}, name: via_tuple(name))
  end

  def init(data) do
    {:ok, data}
  end

  def child_spec(opts) do
    name = Keyword.fetch!(opts, :name)
    contents = Keyword.fetch!(opts, :contents)

    %{
      id: "#{__MODULE__}_#{name}",
      start: {__MODULE__, :start_link, [name, contents]},
      # Allow for up to 10 seconds to shut down
      shutdown: 10_000,
      # Restart if it crashes only
      restart: :transient
    }
  end

  def handle_call(:get_data, _from, {name, data} = state) do
    {:reply, {name, data}, state}
  end

  def get_data(entity_pid) do
    GenServer.call(entity_pid, :get_data)
  end

  def via_tuple(name) do
    {:via, Horde.Registry, {Dynamic.EntityRegistry, name}}
  end
end
