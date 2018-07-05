defmodule Horde.GracefulShutdownManager do
  use GenServer
  require Logger

  def child_spec(options) do
    %{
      id: __MODULE__,
      start:
        {GenServer, :start_link,
         [__MODULE__, Keyword.get(options, :processes_pid), Keyword.take(options, [:name])]}
    }
  end

  def init(processes_pid) do
    {:ok, {processes_pid, false}}
  end

  def handle_call(:horde_shutting_down, _f, {processes_pid, _true_false}) do
    {:reply, :ok, {processes_pid, true}}
  end

  def handle_cast({:shut_down, child_spec}, {processes_pid, true} = s) do
    GenServer.cast(
      processes_pid,
      {:operation, {:add, [child_spec.id, {nil, child_spec}]}}
    )

    {:noreply, s}
  end

  def handle_cast({:shut_down, _child_id}, s) do
    {:noreply, s}
  end
end
