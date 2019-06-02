defmodule MixedTest do
  use ExUnit.Case, async: false

  defmodule TestGenServer do
    use GenServer

    def child_spec(init_fun) do
      %{id: nil, start: {__MODULE__, :start_link, [init_fun]}, restart: :permanent}
    end

    def start_link(init_fun) do
      GenServer.start_link(__MODULE__, init_fun)
    end

    def init(init_fun) do
      init_fun.()
    end
  end

  test "supervisor and registry working together" do
    s1 = start_supervisor()
    s2 = start_supervisor()
    Horde.Cluster.set_members(s1, [s1, s2])
    r1 = start_registry()
    r2 = start_registry()
    Horde.Cluster.set_members(r1, [r1, r2])

    test_count = 1000

    Enum.each(1..test_count, fn x ->
      {:ok, _pid} =
        Horde.Supervisor.start_child(
          s1,
          {TestGenServer,
           fn ->
             reg = Enum.random([r1, r2])

             case Horde.Registry.register(reg, x, nil) do
               {:ok, _pid} -> {:ok, nil}
               {:error, _} -> :ignore
             end
           end}
        )
    end)

    assert %{workers: ^test_count} = Horde.Supervisor.count_children(s1)
    assert %{workers: ^test_count} = Horde.Supervisor.count_children(s2)

    Process.sleep(500)

    :ok = Horde.Supervisor.stop(s1)

    Process.sleep(500)

    assert %{workers: ^test_count} = Horde.Supervisor.count_children(s2)
  end

  defp start_supervisor(opts \\ [strategy: :one_for_one]) do
    name = :"h#{:erlang.monotonic_time()}"
    {:ok, _pid} = Horde.Supervisor.start_link(Keyword.put(opts, :name, name))

    name
  end

  defp start_registry(opts \\ [keys: :unique]) do
    horde = :"h#{-:erlang.monotonic_time()}"
    {:ok, _pid} = Horde.Registry.start_link([name: horde] ++ opts)

    horde
  end
end
