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
       notify: {root_name, :members_updated},
       name: members_crdt_name(root_name),
       sync_interval: 5,
       ship_interval: 5,
       ship_debounce: 1},
      {DeltaCrdt,
       crdt: DeltaCrdt.AWLWWMap,
       notify: {root_name, :registry_updated},
       name: registry_crdt_name(root_name),
       sync_interval: 5,
       ship_interval: 50,
       ship_debounce: 100},
      {DeltaCrdt,
       crdt: DeltaCrdt.AWLWWMap,
       notify: {root_name, :keys_updated},
       name: keys_crdt_name(root_name),
       sync_interval: 5,
       ship_interval: 50,
       ship_debounce: 100},
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

  defp members_crdt_name(name), do: :"#{name}.MembersCrdt"
  defp registry_crdt_name(name), do: :"#{name}.RegistryCrdt"
  defp keys_crdt_name(name), do: :"#{name}.KeysCrdt"
end
