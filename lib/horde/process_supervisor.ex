defmodule Horde.ProcessSupervisor do
  use Supervisor

  def child_spec({child_spec, processes_crdt_pid, node_id}) do
    %{
      id: child_spec.id,
      start: {__MODULE__, :start_link, [child_spec, processes_crdt_pid, node_id]},
      type: :supervisor
    }
  end

  def start_link(child_spec, processes_crdt_pid, node_id) do
    Supervisor.start_link(
      __MODULE__,
      {child_spec, processes_crdt_pid},
      name: name(node_id, child_spec.id)
    )
  end

  def name(node_id, child_id), do: :"#{__MODULE__}.#{Base.encode16(node_id)}.#{child_id}"

  def init({child_spec, processes_crdt_pid}) do
    children = [
      {Horde.ProcessCanary, {child_spec, processes_crdt_pid}}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
