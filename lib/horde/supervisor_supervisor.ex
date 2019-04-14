defmodule Horde.SupervisorSupervisor do
  @moduledoc false

  use Supervisor

  def init(options) do
    root_name = get_root_name(options)

    children = [
      {DeltaCrdt,
       crdt: DeltaCrdt.AWLWWMap,
       on_diffs: fn diffs -> send(root_name, {:crdt_update, diffs}) end,
       name: crdt_name(root_name),
       sync_interval: 100,
       shutdown: 30_000},
      {Horde.SupervisorImpl, Keyword.put(options, :name, root_name)},
      {Horde.GracefulShutdownManager,
       processes_pid: crdt_name(root_name), name: graceful_shutdown_manager_name(root_name)},
      {Horde.DynamicSupervisor,
       Keyword.put(options, :name, supervisor_name(root_name))
       |> Keyword.put(:type, :supervisor)
       |> Keyword.put(:root_name, root_name)
       |> Keyword.put(:graceful_shutdown_manager, graceful_shutdown_manager_name(root_name))
       |> Keyword.put(:shutdown, :infinity)},
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
  defp crdt_name(name), do: :"#{name}.Crdt"
  defp graceful_shutdown_manager_name(name), do: :"#{name}.GracefulShutdownManager"
end
