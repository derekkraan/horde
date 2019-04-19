defmodule Horde.SupervisorSupervisor do
  @moduledoc false

  use Supervisor

  def init(options) do
    root_name = get_root_name(options)

    children = [
      {DeltaCrdt, delta_crdt_options(options)},
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

  defp delta_crdt_options(options) do
    root_name = get_root_name(options)
    crdt_options = Keyword.get(options, :delta_crdt_options, [])
    mutable = [sync_interval: 100, max_sync_size: 500, shutdown: 30_000]

    immutable = [
      crdt: DeltaCrdt.AWLWWMap,
      on_diffs: fn diffs -> on_diffs(diffs, root_name) end,
      name: crdt_name(root_name)
    ]

    Keyword.merge(mutable, crdt_options)
    |> Keyword.merge(immutable)
  end

  defp get_root_name(options) do
    root_name = Keyword.get(options, :root_name, nil)

    if is_nil(root_name) do
      raise "root_name must be specified in options. got: #{inspect(options)}"
    end

    root_name
  end

  defp on_diffs(diffs, root_name) do
    try do
      send(root_name, {:crdt_update, diffs})
    rescue
      ArgumentError ->
        # the process might already been stopped
        :ok
    end
  end

  defp supervisor_name(name), do: :"#{name}.ProcessesSupervisor"
  defp crdt_name(name), do: :"#{name}.Crdt"
  defp graceful_shutdown_manager_name(name), do: :"#{name}.GracefulShutdownManager"
end
