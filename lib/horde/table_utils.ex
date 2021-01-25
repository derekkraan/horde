defmodule Horde.TableUtils do
  @moduledoc false

  def new_table(name) do
    :ets.new(name, [:set, :protected])
  end

  def size_of(table) do
    :ets.info(table, :size)
  end

  def get_item(table, id) do
    case :ets.lookup(table, id) do
      [{_, item}] -> item
      [] -> nil
    end
  end

  def delete_item(table, id) do
    :ets.delete(table, id)
    table
  end

  def pop_item(table, id) do
    item = get_item(table, id)
    delete_item(table, id)
    {item, table}
  end

  def put_item(table, id, item) do
    :ets.insert(table, {id, item})
    table
  end

  def all_items_values(table) do
    :ets.select(table, [{{:"$1", :"$2"}, [], [:"$2"]}])
  end

  def any_item(table, predicate) do
    :ets.tab2list(table) |> Enum.any?(predicate)
  end

end


#defmodule Horde.TableUtils do
#  @moduledoc false
#
#  def new_table(name) do
#    :ets.new(name, [:set, :private])
#  end
#
#  def size_of(table) do
#    map_size(table)
#  end
#
#  def get_item(table, id) do
#    Map.get(table, id)
#  end
#
#  def delete_item(table, id) do
#    Map.delete(table, id)
#  end
#
#  def pop_item(table, id) do
#    Map.pop(table, id)
#  end
#
#  def put_item(table, id, item) do
#    Map.put(table, id, item)
#  end
#
#  def all_items_values(table) do
#    Map.values(table)
#  end
#
#  def any_item(table, predicate) do
#    Enum.any?(table, predicate)
#    #    :ets.tab2list(table) |> Enum.any?(predicate)
#  end
#
#end