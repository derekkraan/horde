defmodule DynamicSupervisorDeadlockTest do
  require Logger
  use ExUnit.Case

  alias Horde.DynamicSupervisor

  setup do
    n1 = :"horde_#{:rand.uniform(100_000_000)}"

    {:ok, horde_1_sup_pid} =
      DynamicSupervisor.start_link(
        name: n1,
        strategy: :one_for_one,
        delta_crdt_options: [sync_interval: 20]
      )

    # give the processes a couple ms to sync up
    Process.sleep(100)

    [
      horde_1: n1,
      horde_1_sup_pid: horde_1_sup_pid
    ]
  end

  defmodule MyServer do
    use GenServer

    def start_link(arg) do
      GenServer.start_link(__MODULE__, arg)
    end

    def init(:crash) do
      Process.sleep(200)
      {:ok, {}, 0}
    end

    def init(:normal) do
      Process.sleep(200)
      {:ok, {}}
    end

    def handle_info(:timeout, _state) do
      raise "crash!"
    end
  end

  test "restart / init deadlock", context do
    # given a process that crashes after a slow init
    {:ok, _} =
      Horde.DynamicSupervisor.start_child(context.horde_1, %{
        restart: :permanent,
        start: {MyServer, :start_link, [:crash]}
      })

    # when we start another "slow" init process
    {:ok, _} =
      Horde.DynamicSupervisor.start_child(context.horde_1, %{
        restart: :permanent,
        start: {MyServer, :start_link, [:normal]}
      })

    # this call used to hang
    assert [_, _] = Horde.DynamicSupervisor.which_children(context.horde_1)
  end
end
