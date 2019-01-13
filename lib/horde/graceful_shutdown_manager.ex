defmodule Horde.GracefulShutdownManager do
  # Horde.GracefulShutdownManager notifies the processes CRDT when a child of the supervisor
  # is terminated and the node is shutting down.
  #
  # This ensures a smooth transition when a node is shutting down. If we did not do this here,
  # then we would have to wait until all children of the supervisor were done shutting down
  # before releasing them to be restarted on other nodes. If some child processes take much
  # longer than others to terminate, then this will result in some child processes being
  # unavailable for longer than necessary.
  @moduledoc false

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
