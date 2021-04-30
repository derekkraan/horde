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
    try do
      :ets.safe_fixtable(table, true)
      first_key = :ets.first(table)
      ets_any?(table, predicate, first_key)
    after
      :ets.safe_fixtable(table, false)
    end
  end

  def ets_any?(_table, _predicate, :"$end_of_table") do
    false
  end

  def ets_any?(table, predicate, key) do
    entry = get_item(table, key)

    if predicate.(entry) do
      true
    else
      ets_any?(table, predicate, :ets.next(table, key))
    end
  end
end
