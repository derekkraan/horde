defmodule Horde.ProcessSupervisor do
  # We wrap processes to be able to inject some functionality which is necessary for
  # the functioning of Horde.Supervisor.
  #
  # 1. registering the pid of this process by its child_id so that it can be referenced by id.
  # 2. starting a ProcessCanary which will only be shut down after the child process is shut down,
  #    which allows a sort of callback functionality. This could not easily be achieved with links,
  #    because we need to send the CRDT some additional information that is then not available.
  @moduledoc false

  use Supervisor

  def child_spec({child_spec, graceful_shutdown_manager, registry_name, options}) do
    %{
      id: child_spec.id,
      start:
        {__MODULE__, :start_link, [child_spec, graceful_shutdown_manager, registry_name, options]},
      type: :supervisor
    }
  end

  def start_link(child_spec, graceful_shutdown_manager, registry_name, options) do
    Supervisor.start_link(
      __MODULE__,
      {child_spec, graceful_shutdown_manager, options},
      name: {:via, Registry, {registry_name, child_spec.id, nil}}
    )
  end

  def init({child_spec, graceful_shutdown_manager, options}) do
    options = Keyword.put(options, :strategy, :one_for_one)

    children = [
      {Horde.ProcessCanary, {child_spec, graceful_shutdown_manager}}
    ]

    Supervisor.init(children, options)
  end
end
