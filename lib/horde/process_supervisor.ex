defmodule Horde.ProcessSupervisor do
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
      {child_spec, graceful_shutdown_manager, registry_name, options}
    )
  end

  def init({child_spec, graceful_shutdown_manager, registry_name, options}) do
    options = Keyword.put(options, :strategy, :one_for_one)

    {:ok, _pid} = Registry.register(registry_name, child_spec.id, nil)

    children = [
      {Horde.ProcessCanary, {child_spec, graceful_shutdown_manager}}
    ]

    Supervisor.init(children, options)
  end
end
