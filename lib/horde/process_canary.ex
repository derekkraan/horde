defmodule Horde.ProcessCanary do
  @moduledoc false

  use GenServer

  def child_spec(args) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [args]}, shutdown: 1_000}
  end

  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  def init({child_spec, graceful_shutdown_manager}) do
    Process.flag(:trap_exit, true)
    {:ok, {child_spec, graceful_shutdown_manager}}
  end

  def terminate(_reason, {child_spec, graceful_shutdown_manager}) do
    GenServer.cast(graceful_shutdown_manager, {:shut_down, child_spec})
  end
end
