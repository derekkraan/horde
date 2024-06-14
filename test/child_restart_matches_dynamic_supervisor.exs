defmodule ClusterTest do
  use ExUnit.Case

  defmodule BasicGenServer do
    use GenServer

    def init(init_arg) do
      {:ok, init_arg}
    end

    def start_link(arg) do
      GenServer.start_link(__MODULE__, arg)
    end
  end


  test "(Process.exit(pid, :kill)) DynamicSupervisor vs Horde.DynamicSupervisor with pids" do
    name = :"supervisor_#{:rand.uniform(100_000_000)}"
    {:ok, sup_pid} = DynamicSupervisor.start_link(name: name, strategy: :one_for_one)

    {:ok, child1} = DynamicSupervisor.start_child(sup_pid, %{id: :child1, start: {BasicGenServer, :start_link, [0]}})
    {:ok, child2} = DynamicSupervisor.start_child(sup_pid, %{id: :child2, start: {BasicGenServer, :start_link, [0]}})
    {:ok, child3} = DynamicSupervisor.start_child(sup_pid, %{id: :child3, start: {BasicGenServer, :start_link, [0]}})

    true = Process.exit(child3, :kill)
    Process.sleep(1000)
    assert Process.alive?(child1)
    assert Process.alive?(child2)
    assert !Process.alive?(child3)
    children = DynamicSupervisor.which_children(sup_pid)

    assert Enum.count(children, fn {_id, _pid, _type, mod} -> [BasicGenServer] == mod end) == 3
    name = :"supervisor_#{:rand.uniform(100_000_000)}"
    {:ok, sup_pid} = Horde.DynamicSupervisor.start_link(name: name, strategy: :one_for_one)

    {:ok, child1} = Horde.DynamicSupervisor.start_child(sup_pid, %{id: :child1, start: {BasicGenServer, :start_link, [0]}})
    {:ok, child2} = Horde.DynamicSupervisor.start_child(sup_pid, %{id: :child2, start: {BasicGenServer, :start_link, [0]}})
    {:ok, child3} = Horde.DynamicSupervisor.start_child(sup_pid, %{id: :child3, start: {BasicGenServer, :start_link, [0]}})

    true = Process.exit(child3, :kill)
    Process.sleep(1000)
    assert Process.alive?(child1)
    assert Process.alive?(child2)
    assert !Process.alive?(child3)
    children = Horde.DynamicSupervisor.which_children(sup_pid)

    assert Enum.count(children, fn {_id, _pid, _type, mod} -> [BasicGenServer] == mod end) == 3
  end

  test "(Process.exit(pid, :kill)) DynamicSupervisor vs Horde.DynamicSupervisor with names" do
    name = :"supervisor_#{:rand.uniform(100_000_000)}"

    {:ok, _sup_pid} = DynamicSupervisor.start_link(name: name, strategy: :one_for_one)

    {:ok, child1} = DynamicSupervisor.start_child(name, %{id: :child1, start: {BasicGenServer, :start_link, [0]}})
    {:ok, child2} = DynamicSupervisor.start_child(name, %{id: :child2, start: {BasicGenServer, :start_link, [0]}})
    {:ok, child3} = DynamicSupervisor.start_child(name, %{id: :child3, start: {BasicGenServer, :start_link, [0]}})

    true = Process.exit(child3, :kill)
    Process.sleep(1000)
    assert Process.alive?(child1)
    assert Process.alive?(child2)
    assert !Process.alive?(child3)
    children = DynamicSupervisor.which_children(name)

    assert Enum.count(children, fn {_id, _pid, _type, mod} -> [BasicGenServer] == mod end) == 3
    name = :"supervisor_#{:rand.uniform(100_000_000)}"

    {:ok, _sup_pid} = Horde.DynamicSupervisor.start_link(name: name, strategy: :one_for_one)

    {:ok, child1} = Horde.DynamicSupervisor.start_child(name, %{id: :child1, start: {BasicGenServer, :start_link, [0]}})
    {:ok, child2} = Horde.DynamicSupervisor.start_child(name, %{id: :child2, start: {BasicGenServer, :start_link, [0]}})
    {:ok, child3} = Horde.DynamicSupervisor.start_child(name, %{id: :child3, start: {BasicGenServer, :start_link, [0]}})

    true = Process.exit(child3, :kill)
    Process.sleep(1000)
    assert Process.alive?(child1)
    assert Process.alive?(child2)
    assert !Process.alive?(child3)
    children = Horde.DynamicSupervisor.which_children(name)

    assert Enum.count(children, fn {_id, _pid, _type, mod} -> [BasicGenServer] == mod end) == 3

  end

  test "DynamicSupervisor.terminate_child/2 vs Horde.DynamicSupervisor.terminate_child/2 with pids" do
    name = :"supervisor_#{:rand.uniform(100_000_000)}"
    {:ok, sup_pid} = DynamicSupervisor.start_link(name: name, strategy: :one_for_one)

    {:ok, child1} = DynamicSupervisor.start_child(sup_pid, %{id: :child1, start: {BasicGenServer, :start_link, [0]}})
    {:ok, child2} = DynamicSupervisor.start_child(sup_pid, %{id: :child2, start: {BasicGenServer, :start_link, [0]}})
    {:ok, child3} = DynamicSupervisor.start_child(sup_pid, %{id: :child3, start: {BasicGenServer, :start_link, [0]}})

    :ok = DynamicSupervisor.terminate_child(sup_pid, child3)
    Process.sleep(1000)
    assert Process.alive?(child1)
    assert Process.alive?(child2)
    assert !Process.alive?(child3)
    children = DynamicSupervisor.which_children(sup_pid)

    assert Enum.count(children, fn {_id, _pid, _type, mod} -> [BasicGenServer] == mod end) == 2
    name = :"supervisor_#{:rand.uniform(100_000_000)}"
    {:ok, sup_pid} = Horde.DynamicSupervisor.start_link(name: name, strategy: :one_for_one)

    {:ok, child1} = Horde.DynamicSupervisor.start_child(sup_pid, %{id: :child1, start: {BasicGenServer, :start_link, [0]}})
    {:ok, child2} = Horde.DynamicSupervisor.start_child(sup_pid, %{id: :child2, start: {BasicGenServer, :start_link, [0]}})
    {:ok, child3} = Horde.DynamicSupervisor.start_child(sup_pid, %{id: :child3, start: {BasicGenServer, :start_link, [0]}})

    :ok = Horde.DynamicSupervisor.terminate_child(sup_pid, child3)
    Process.sleep(1000)
    assert Process.alive?(child1)
    assert Process.alive?(child2)
    assert !Process.alive?(child3)
    children = Horde.DynamicSupervisor.which_children(sup_pid)

    assert Enum.count(children, fn {_id, _pid, _type, mod} -> [BasicGenServer] == mod end) == 2
  end

  test "DynamicSupervisor.terminate_child/2 vs Horde.DynamicSupervisor.terminate_child/2 with names" do
    name = :"supervisor_#{:rand.uniform(100_000_000)}"

    {:ok, _sup_pid} = DynamicSupervisor.start_link(name: name, strategy: :one_for_one)

    {:ok, child1} = DynamicSupervisor.start_child(name, %{id: :child1, start: {BasicGenServer, :start_link, [0]}})
    {:ok, child2} = DynamicSupervisor.start_child(name, %{id: :child2, start: {BasicGenServer, :start_link, [0]}})
    {:ok, child3} = DynamicSupervisor.start_child(name, %{id: :child3, start: {BasicGenServer, :start_link, [0]}})

    :ok = DynamicSupervisor.terminate_child(name, child3)
    Process.sleep(1000)
    assert Process.alive?(child1)
    assert Process.alive?(child2)
    assert !Process.alive?(child3)
    children = DynamicSupervisor.which_children(name)

    assert Enum.count(children, fn {_id, _pid, _type, mod} -> [BasicGenServer] == mod end) == 2
    name = :"supervisor_#{:rand.uniform(100_000_000)}"

    {:ok, _sup_pid} = Horde.DynamicSupervisor.start_link(name: name, strategy: :one_for_one)

    {:ok, child1} = Horde.DynamicSupervisor.start_child(name, %{id: :child1, start: {BasicGenServer, :start_link, [0]}})
    {:ok, child2} = Horde.DynamicSupervisor.start_child(name, %{id: :child2, start: {BasicGenServer, :start_link, [0]}})
    {:ok, child3} = Horde.DynamicSupervisor.start_child(name, %{id: :child3, start: {BasicGenServer, :start_link, [0]}})

    :ok = Horde.DynamicSupervisor.terminate_child(name, child3)
    Process.sleep(1000)
    assert Process.alive?(child1)
    assert Process.alive?(child2)
    assert !Process.alive?(child3)
    children = Horde.DynamicSupervisor.which_children(name)

    assert Enum.count(children, fn {_id, _pid, _type, mod} -> [BasicGenServer] == mod end) == 2
  end
end
