defmodule NetSplitTest do
  use ExUnit.Case
  require Logger

  @tag :skip
  test "test netsplit" do
    nodes = LocalCluster.start_nodes("loner-cluster", 4, files: [__ENV__.file])

    [n1, n2, n3, _n4] = nodes

    Enum.each(nodes, &Node.spawn(&1, __MODULE__, :setup_horde, [nodes]))

    Process.sleep(1000)

    num_procs = 1000

    Enum.each(1..num_procs, fn x ->
      {:ok, _pid} =
        :erpc.call(n1, Horde.DynamicSupervisor, :start_child, [
          TestNetSplitSup,
          {TestNetSplitServer, name: :"test_netsplit_server_#{x}"}
        ])
    end)

    Process.sleep(1000)

    Logger.info("CREATING SCHISM")

    g1 = [n1, n2]
    Schism.partition(g1)

    Process.sleep(2000)

    Logger.debug("CHECKING NODE 1")

    pids =
      Enum.map(1..num_procs, fn x ->
        pid =
          :erpc.call(n1, Horde.Registry, :whereis_name, [
            {TestReg2, :"test_netsplit_server_#{x}"}
          ])

        assert {:"server_#{x}", pid, is_pid(pid)} == {:"server_#{x}", pid, true}
        pid
      end)

    assert pids |> Enum.uniq() |> length == num_procs
    assert Enum.all?(pids, &is_pid/1)

    Logger.debug("CHECKING NODE 3")

    pids =
      Enum.map(1..num_procs, fn x ->
        pid =
          :erpc.call(n3, Horde.Registry, :whereis_name, [
            {TestReg2, :"test_netsplit_server_#{x}"}
          ])

        assert {:"server_#{x}", pid, is_pid(pid)} == {:"server_#{x}", pid, true}
        pid
      end)

    assert pids |> Enum.uniq() |> length == num_procs
    assert Enum.all?(pids, &is_pid/1)

    Logger.info("HEALING SCHISM")

    Schism.heal(nodes)

    Process.sleep(2000)

    pids =
      Enum.map(1..num_procs, fn x ->
        pid =
          :erpc.call(hd(nodes), Horde.Registry, :whereis_name, [
            {TestReg2, :"test_netsplit_server_#{x}"}
          ])

        assert {:"server_#{x}", pid, is_pid(pid)} == {:"server_#{x}", pid, true}
        pid
      end)

    :erpc.call(hd(nodes), Horde.DynamicSupervisor, :which_children, [TestNetSplitSup])

    assert pids |> Enum.uniq() |> length == num_procs
    assert Enum.all?(pids, &is_pid/1)
  end

  def setup_horde(nodes) do
    {:ok, _} = Application.ensure_all_started(:horde)

    registries = for n <- nodes, do: {TestReg2, n}
    supervisors = for n <- nodes, do: {TestNetSplitSup, n}

    {:ok, _} =
      Horde.Registry.start_link(
        name: TestReg2,
        keys: :unique,
        delta_crdt_options: [sync_interval: 250],
        members: registries
      )

    {:ok, _} =
      Horde.DynamicSupervisor.start_link(
        name: TestNetSplitSup,
        strategy: :one_for_one,
        delta_crdt_options: [sync_interval: 200],
        members: supervisors
      )

    :telemetry.attach(
      "delta-crdt-syncs",
      [:delta_crdt, :sync, :done],
      fn _, %{keys_updated_count: count}, _, _ ->
        Logger.debug("#{inspect(node())} delta_crdt synced #{count} keys")
      end,
      nil
    )

    receive do
    end
  end
end

defmodule TestNetSplitServer do
  require Logger
  use GenServer, restart: :transient

  def start_link(args) do
    GenServer.start_link(__MODULE__, args,
      name: {:via, Horde.Registry, {TestReg2, Keyword.get(args, :name)}}
    )
    |> case do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        Logger.debug(
          "#{inspect(node())} #{inspect(pid)} server_#{Keyword.get(args, :name)} already started"
        )

        :ignore
    end
  end

  def init(args) do
    Process.flag(:trap_exit, true)

    Logger.debug(
      "#{inspect(node())} #{inspect(self())} server_#{Keyword.get(args, :name)} started"
    )

    do_ping(args)

    {:ok, args}
  end

  def handle_info(:ping, state) do
    do_ping(state)
    {:noreply, state}
  end

  def handle_info({:EXIT, _, {:name_conflict, _, _, _}} = _msg, state) do
    Logger.debug(
      "#{inspect(node())} #{inspect(self())} server_#{Keyword.get(state, :name)} stopped because of name conflict"
    )

    {:stop, :normal, state}
  end

  defp do_ping(state) do
    Logger.debug(
      "#{inspect(node())} #{inspect(self())} server_#{Keyword.get(state, :name)} still running"
    )

    Process.send_after(self(), :ping, 100)
  end

  def terminate(state) do
    Logger.debug(
      "#{inspect(node())} #{inspect(self())} server_#{Keyword.get(state, :name)} terminated normally"
    )
  end
end
