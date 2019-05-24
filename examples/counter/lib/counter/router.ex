defmodule Counter.Router.PID do
  def increment(name) do
    Counter.Router.lookup_and_start_if_needed(name)
    |> GenServer.cast(:increment)
  end

  def value(name) do
    Counter.Router.lookup_and_start_if_needed(name)
    |> GenServer.call(:value)
  end
end

defmodule Counter.Router.Via do
  def increment(name) do
    Counter.Router.lookup_and_start_if_needed(name)
    GenServer.cast(Counter.Worker.via_tuple(name), :increment)
  end

  def value(name) do
    Counter.Router.lookup_and_start_if_needed(name)
    GenServer.call(Counter.Worker.via_tuple(name), :value)
  end
end

defmodule Counter.Router do
  @doc """
  This is the central part of this example.  It uses `Horde.Registry` to find
  a Counter process for the specified name.

  * If one is found, it retuns the PID of that process
  * If one is not found, it starts one using `Horde.Supervisor.start_child` and
    returns its PID
  * This implementation also deals with the situation where the Registry does 
    not yet know about the process, but the `Horde.Supervisor` would return an
    `:already_started` with a pid (but this seems like a hacky way to handle
    this condition and would only work if the Process exists on the same node).
  """
  def lookup_and_start_if_needed(name) do
    case Horde.Registry.lookup(Counter.Registry, name) do
      [{pid, _}] ->
        pid

      :undefined ->
        case Horde.Supervisor.start_child(Counter.CounterSupervisor, {Counter.Worker, name: name}) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} when is_pid(pid) -> pid
        end
    end
  end
end
