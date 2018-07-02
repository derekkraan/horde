defmodule Horde.ProcessCanary do
  use GenServer
  @crdt DeltaCrdt.AWLWWMap

  def child_spec(args) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [args]}, shutdown: 1_000}
  end

  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  def init({child_spec, processes_pid}) do
    Process.flag(:trap_exit, true)
    {:ok, {child_spec, processes_pid}}
  end

  def terminate(reason, {child_spec, processes_pid}) do
    GenServer.cast(
      processes_pid,
      {:operation, {@crdt, :add, [child_spec.id, {nil, child_spec}]}}
    )
  end
end
