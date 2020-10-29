defmodule NestedSupervisionTest do
  require Logger
  use ExUnit.Case

  defmodule TestChild do
    use GenServer

    def start_link(_) do
      GenServer.start_link(__MODULE__, [], name: __MODULE__)
    end

    def init(_) do
      {:ok, []}
    end

    def handle_cast(:boom, _) do
      {:stop, :normal, []}
    end
  end

  defmodule TestSupervisor do
    use Supervisor

    def start_link(arg) do
      Supervisor.start_link(__MODULE__, arg, [])
    end

    def init(arg) do
      children = [
        {Horde.DynamicSupervisor,
         [
           name: TestHorde,
           strategy: :one_for_one,
           max_restarts: 1
         ]},
        %{
          id: AddsChild,
          restart: :transient,
          start:
            {Task, :start_link,
             [
               fn ->
                 Horde.DynamicSupervisor.start_child(TestHorde, TestChild)
               end
             ]}
        }
      ]

      case arg do
        "with rest_for_one" -> Supervisor.init(children, strategy: :rest_for_one)
        "with one_for_one" -> Supervisor.init(children, strategy: :one_for_one)
      end
    end
  end

  defp crash_dynamic_supervisor() do
    :timer.sleep(50)

    GenServer.cast(TestHorde, :boom)
  end

  defp crash_child_process() do
    :timer.sleep(50)

    GenServer.cast(TestChild, :boom)
  end

  setup %{describe: describe} do
    start_supervised({TestSupervisor, describe})
    :ok
  end

  describe "with one_for_one" do
    test "child can restart once", _ do
      crash_child_process()

      :timer.sleep(50)

      assert %{active: 1} = Horde.DynamicSupervisor.count_children(TestHorde)
    end

    test "child is gone after crashing DynamicSupervisor", _ do
      crash_dynamic_supervisor()

      :timer.sleep(50)

      assert %{active: 0} = Horde.DynamicSupervisor.count_children(TestHorde)
    end

    test "child is gone after it crashes twice", _ do
      crash_child_process()

      crash_child_process()

      :timer.sleep(50)

      assert %{active: 0} = Horde.DynamicSupervisor.count_children(TestHorde)
    end
  end

  describe "with rest_for_one" do
    test "child gets restored when crashing DynamicSupervisor", _ do
      crash_dynamic_supervisor()

      :timer.sleep(50)

      assert %{active: 1} = Horde.DynamicSupervisor.count_children(TestHorde)
    end

    test "child gets restored after it crashes twice", _ do
      crash_child_process()

      crash_child_process()

      :timer.sleep(50)

      assert %{active: 1} = Horde.DynamicSupervisor.count_children(TestHorde)
    end
  end
end
