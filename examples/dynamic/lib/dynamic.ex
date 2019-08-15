defmodule Dynamic do
  def create_entity(name, contents) do
    Horde.Supervisor.start_child(
      Dynamic.EntitySupervisor,
      {Dynamic.Entity, [name: name, contents: contents]}
    )
  end

  def get_entity(name) do
    name
    |> get_entity_pid()
    |> Dynamic.Entity.get_data()
    |> elem(1)
  end

  def get_entity_pid(name) do
    case Horde.Registry.lookup(Dynamic.EntityRegistry, name) do
      :undefined -> nil
      [{pid, _}] -> pid
    end
  end
end
