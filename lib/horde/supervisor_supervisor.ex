defmodule Horde.SupervisorSupervisor do
  @moduledoc false

  use Supervisor

  def init(options) do
    root_name = get_root_name(options)

    IO.inspect(options)

    DynamicSupervisor.child_spec(
      Keyword.put(options, :name, supervisor_name(root_name))
      |> Keyword.put(:type, :supervisor)
    )
    |> IO.inspect()

    children = [
      {DeltaCrdt,
       crdt: DeltaCrdt.AWLWWMap,
       notify: {root_name, :members_updated},
       name: members_crdt_name(root_name),
       sync_interval: 5,
       ship_interval: 5,
       ship_debounce: 1,
       shutdown: 30_000},
      {DeltaCrdt,
       crdt: DeltaCrdt.AWLWWMap,
       notify: {root_name, :processes_updated},
       name: processes_crdt_name(root_name),
       sync_interval: 50,
       ship_interval: 50,
       ship_debounce: 400,
       shutdown: 30_000},
      {Horde.SupervisorImpl, Keyword.put(options, :name, root_name)},
      {Horde.GracefulShutdownManager,
       processes_pid: processes_crdt_name(root_name),
       name: graceful_shutdown_manager_name(root_name)},
      {DynamicSupervisor,
       Keyword.put(options, :name, supervisor_name(root_name))
       |> Keyword.put(:type, :supervisor)},
      {Horde.SignalShutdown, signal_to: [graceful_shutdown_manager_name(root_name), root_name]}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end

  defp get_root_name(options) do
    root_name = Keyword.get(options, :root_name, nil)

    if is_nil(root_name) do
      raise "root_name must be specified in options. got: #{inspect(options)}"
    end

    root_name
  end

  defp supervisor_name(name), do: :"#{name}.ProcessesSupervisor"
  defp members_crdt_name(name), do: :"#{name}.MembersCrdt"
  defp processes_crdt_name(name), do: :"#{name}.ProcessesCrdt"
  defp graceful_shutdown_manager_name(name), do: :"#{name}.GracefulShutdownManager"
end
