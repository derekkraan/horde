defmodule Worker do
  require Logger

  defstruct name: "",
            state: ""

  def state(name) do
    GenServer.call(via_tuple(name), :state)
  end

  def set_state(pid, state) when is_pid(pid) do
    GenServer.call(pid, {:set_state, state})
  end

  def set_state(name, state) do
    GenServer.call(via_tuple(name), {:set_state, state})
  end

  def start(name) do
    Horde.DynamicSupervisor.start_child(
      TestSup,
      child_spec(name: name)
    )
  end

  def via_tuple(name) do
    {:via, Horde.Registry, {TestReg, name}}
  end

  def start_link(name) do
    GenServer.start_link(__MODULE__, name, name: via_tuple(name))
  end

  def init(name) do
    Logger.info("Starting worker on #{inspect(Node.self())}")
    {:ok, %__MODULE__{name: name}, {:continue, :started}}
  end

  def handle_continue(:started, state) do
    Logger.info("Started worker on #{inspect(Node.self())}")
    {:noreply, state}
  end

  def handle_call({:set_state, value}, _from, state) do
    {:reply, :ok, %{state | state: value}}
  end

  def handle_call(:state, _from, state) do
    {:reply, {:ok, state.state}, state}
  end

  defp child_spec(name: name) do
    %{
      id: String.to_atom("#{__MODULE__}_#{name}"),
      start: {__MODULE__, :start_link, [name]},
      shutdown: 10_000
    }
  end
end
