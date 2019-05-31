defmodule Horde.RegistrySupervisor do
  @moduledoc false

  use Supervisor

  def init(options) do
    root_name = get_root_name(options)

    unless is_atom(root_name) do
      raise ArgumentError,
            "expected :root_name to be given and to be an atom, got: #{inspect(root_name)}"
    end

    children = [
      {DeltaCrdt,
       crdt: DeltaCrdt.AWLWWMap,
       on_diffs: fn diffs -> on_diffs(diffs, root_name) end,
       name: crdt_name(root_name),
       sync_interval: 100},
      {Horde.RegistryImpl,
       name: root_name,
       meta: Keyword.get(options, :meta),
       members: Keyword.get(options, :members),
       init_module: Keyword.get(options, :init_module)}
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

  defp on_diffs(diffs, root_name) do
    try do
      send(root_name, {:crdt_update, diffs})
    rescue
      ArgumentError ->
        # the process might already been stopped
        :ok
    end
  end

  def crdt_name(name), do: :"#{name}.Crdt"
end
