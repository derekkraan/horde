defmodule RegistryTest do
  use ExUnit.Case, async: true
  doctest Horde.Registry

  describe ".start_link/1" do
    test "only keys: :unique is allowed" do
      assert_raise ArgumentError, fn ->
        Horde.Registry.start_link(name: :horde_not_unique, keys: :duplicate)
      end
    end
  end

  describe "module-based Registry" do
    test "can use `init` function to dynamically fetch configuration" do
      {:ok, _} = TestRegistry1.start_link(name: :init_test_1, keys: :unique)
      {:ok, _} = TestRegistry2.start_link(name: :init_test_2, keys: :unique)
      {:ok, members} = Horde.Cluster.members(:init_test_1)
      assert 2 = Enum.count(members)
    end
  end

  describe ".set_members/2" do
    test "two hordes can join each other" do
      horde1 = start_registry()
      horde2 = start_registry()

      Horde.Cluster.set_members(horde1, [horde1, horde2])
      Process.sleep(50)
      {:ok, members} = Horde.Cluster.members(horde2)
      assert 2 = Enum.count(members)
    end

    test "three nodes can make a single registry" do
      horde1 = start_registry()
      horde2 = start_registry()
      horde3 = start_registry()

      Horde.Cluster.set_members(horde1, [horde1, horde2, horde3])
      Process.sleep(100)
      {:ok, members} = Horde.Cluster.members(horde2)
      assert 3 = Enum.count(members)
    end
  end

  describe ".register/3" do
    test "has unique registrations" do
      horde = start_registry()

      {:ok, pid} = Horde.Registry.register(horde, "hello", :value)
      assert is_pid(pid)
      assert Horde.Registry.keys(horde, self()) == ["hello"]

      assert {:error, {:already_registered, pid}} =
               Horde.Registry.register(horde, "hello", :value)

      assert pid == self()
      assert Horde.Registry.keys(horde, self()) == ["hello"]

      {:ok, pid} = Horde.Registry.register(horde, "world", :value)
      assert is_pid(pid)
      assert Horde.Registry.keys(horde, self()) |> Enum.sort() == ["hello", "world"]
    end

    test "has unique registrations across processes" do
      horde = start_registry()

      {_, task} = register_task(horde, "hello", :value)
      Process.link(Process.whereis(horde))

      assert {:error, {:already_registered, ^task}} =
               Horde.Registry.register(horde, "hello", :recent)

      assert Horde.Registry.keys(horde, self()) == []
      {:links, links} = Process.info(self(), :links)
      assert Process.whereis(horde) in links
    end

    test "name conflict message is received when 2 registries join" do
      horde1 = start_registry()
      horde2 = start_registry()

      {:ok, _} = Horde.Registry.register(horde1, "hello", :value)

      winner_pid =
        spawn_link(fn ->
          {:ok, _} = Horde.Registry.register(horde2, "hello", :value)
          Process.sleep(:infinity)
        end)

      Process.flag(:trap_exit, true)
      Horde.Cluster.set_members(horde1, [horde1, horde2])

      assert_receive {:EXIT, _from, {:name_conflict, {"hello", :value}, ^horde1, ^winner_pid}}

      Process.flag(:trap_exit, false)

      # only the winner process is registered
      assert %{"hello" => {winner_pid, :value}} == Horde.Registry.processes(horde1)
      assert %{"hello" => {winner_pid, :value}} == Horde.Registry.processes(horde2)
    end

    test "name conflicts in separate processes" do
      horde1 = start_registry()
      horde2 = start_registry()

      process = fn horde ->
        fn ->
          {:ok, _} = Horde.Registry.register(horde, "name", nil)
          {:ok, _} = Horde.Registry.register(horde, {:other, make_ref()}, nil)
          Process.sleep(:infinity)
        end
      end

      pid1 = spawn(process.(horde1))
      Process.sleep(10)
      pid2 = spawn(process.(horde2))

      Horde.Cluster.set_members(horde1, [horde1, horde2])

      Process.sleep(100)

      # pid1 has lost
      refute Process.alive?(pid1)

      assert [{:other, _}, "name"] = Map.keys(Horde.Registry.processes(horde1)) |> Enum.sort()
      assert [{:other, _}, "name"] = Map.keys(Horde.Registry.processes(horde2)) |> Enum.sort()
    end
  end

  describe ".keys/2" do
    test "empty list if not registered" do
      horde = start_registry()
      assert [] = Horde.Registry.keys(horde, self())
    end

    test "registered keys are returned" do
      horde = start_registry()
      horde2 = start_registry()

      Horde.Cluster.set_members(horde, [horde, horde2])

      Horde.Registry.register(horde, "foo", :value)
      Horde.Registry.register(horde2, "bar", :value)

      Process.sleep(1000)

      assert Enum.sort(["foo", "bar"]) == Enum.sort(Horde.Registry.keys(horde, self()))
    end
  end

  describe ".select/2" do
    test "empty list for empty registry" do
      horde = start_registry()
      assert Horde.Registry.select(horde, [{{:_, :_, :_}, [], [:"$_"]}]) == []
    end

    test "select all" do
      horde = start_registry()

      name = {:via, Horde.Registry, {horde, "hello"}}
      {:ok, pid} = Agent.start_link(fn -> 0 end, name: name)
      {:ok, _} = Horde.Registry.register(horde, "world", :value)

      assert Horde.Registry.select(horde, [
               {{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}
             ])
             |> Enum.sort() == [{"hello", pid, nil}, {"world", self(), :value}]
    end

    test "select supports full match specs" do
      horde = start_registry()

      value = {1, :atom, 1}
      {:ok, _} = Horde.Registry.register(horde, "hello", value)

      assert [{"hello", self(), value}] ==
               Horde.Registry.select(horde, [
                 {{"hello", :"$2", :"$3"}, [], [{{"hello", :"$2", :"$3"}}]}
               ])

      assert [{"hello", self(), value}] ==
               Horde.Registry.select(horde, [
                 {{:"$1", self(), :"$3"}, [], [{{:"$1", self(), :"$3"}}]}
               ])

      assert [{"hello", self(), value}] ==
               Horde.Registry.select(horde, [
                 {{:"$1", :"$2", value}, [], [{{:"$1", :"$2", {value}}}]}
               ])

      assert [] ==
               Horde.Registry.select(horde, [
                 {{"world", :"$2", :"$3"}, [], [{{"world", :"$2", :"$3"}}]}
               ])

      assert [] == Horde.Registry.select(horde, [{{:"$1", :"$2", {1.0, :_, :_}}, [], [:"$_"]}])

      assert [{"hello", self(), value}] ==
               Horde.Registry.select(horde, [
                 {{:"$1", :"$2", {:"$3", :atom, :"$4"}}, [],
                  [{{:"$1", :"$2", {{:"$3", :atom, :"$4"}}}}]}
               ])

      assert [{"hello", self(), {1, :atom, 1}}] ==
               Horde.Registry.select(horde, [
                 {{:"$1", :"$2", {:"$3", :"$4", :"$3"}}, [],
                  [{{:"$1", :"$2", {{:"$3", :"$4", :"$3"}}}}]}
               ])

      value2 = %{a: "a", b: "b"}
      {:ok, _} = Horde.Registry.register(horde, "world", value2)

      assert [:match] ==
               Horde.Registry.select(horde, [{{"world", self(), %{b: "b"}}, [], [:match]}])

      assert ["hello", "world"] ==
               Horde.Registry.select(horde, [{{:"$1", :_, :_}, [], [:"$1"]}]) |> Enum.sort()
    end

    test "select supports guard conditions" do
      horde = start_registry()

      value = {1, :atom, 2}
      {:ok, _} = Horde.Registry.register(horde, "hello", value)

      assert [{"hello", self(), {1, :atom, 2}}] ==
               Horde.Registry.select(horde, [
                 {{:"$1", :"$2", {:"$3", :"$4", :"$5"}}, [{:>, :"$5", 1}],
                  [{{:"$1", :"$2", {{:"$3", :"$4", :"$5"}}}}]}
               ])

      assert [] ==
               Horde.Registry.select(horde, [
                 {{:_, :_, {:_, :_, :"$1"}}, [{:>, :"$1", 2}], [:"$_"]}
               ])

      assert ["hello"] ==
               Horde.Registry.select(horde, [
                 {{:"$1", :_, {:_, :"$2", :_}}, [{:is_atom, :"$2"}], [:"$1"]}
               ])
    end

    test "select allows multiple specs" do
      horde = start_registry()

      {:ok, _} = Horde.Registry.register(horde, "hello", :value)
      {:ok, _} = Horde.Registry.register(horde, "world", :value)

      assert ["hello", "world"] ==
               Horde.Registry.select(horde, [
                 {{"hello", :_, :_}, [], [{:element, 1, :"$_"}]},
                 {{"world", :_, :_}, [], [{:element, 1, :"$_"}]}
               ])
               |> Enum.sort()
    end

    test "select works with clustered registries" do
      horde1 = :select_clustered_a
      horde2 = :select_clustered_b
      {:ok, _} = Horde.Registry.start_link(name: horde1, keys: :unique)
      {:ok, _} = Horde.Registry.start_link(name: horde2, keys: :unique)
      Horde.Cluster.set_members(horde1, [horde1, horde2])

      {:ok, _} = Horde.Registry.register(horde1, "a", :value)
      Process.sleep(100)

      assert ["a"] = Horde.Registry.select(horde1, [{{:"$1", :_, :_}, [], [:"$1"]}])
      assert ["a"] = Horde.Registry.select(horde2, [{{:"$1", :_, :_}, [], [:"$1"]}])
    end

    test "raises on incorrect shape of match spec" do
      horde = start_registry()

      assert_raise ArgumentError, fn ->
        Horde.Registry.select(horde, [{:_, [], []}])
      end
    end
  end

  describe "register via callbacks" do
    test "register a name the 'via' way" do
      horde = start_registry()

      name = {:via, Horde.Registry, {horde, "precious"}}
      {:ok, apid} = Agent.start_link(fn -> 0 end, name: name)
      Process.sleep(10)
      assert 0 = Agent.get(name, & &1)
      assert [{apid, nil}] == Horde.Registry.lookup(horde, "precious")
    end
  end

  describe ".unregister/2" do
    test "can unregister processes" do
      horde = start_registry()
      horde2 = start_registry()
      Horde.Cluster.set_members(horde, [horde, horde2])

      Horde.Registry.register(horde, :one_day_fly, "value")
      assert %{one_day_fly: _id} = Horde.Registry.processes(horde)
      Process.sleep(200)
      assert %{one_day_fly: _id} = Horde.Registry.processes(horde2)

      Horde.Registry.unregister(horde, :one_day_fly)
      assert %{} == Horde.Registry.processes(horde)
      Process.sleep(200)
      assert %{} == Horde.Registry.processes(horde2)
    end
  end

  describe ".unregister_match/4" do
    test "unregisters matching processes" do
      horde = start_registry()

      Horde.Registry.register(horde, "to_unregister", "match_unregister")
      Horde.Registry.register(horde, "another_key", value: 12)

      :ok =
        Horde.Registry.unregister_match(
          horde,
          "another_key",
          [value: :"$1"],
          [{:>, :"$1", 12}]
        )

      assert Enum.sort(["another_key", "to_unregister"]) ==
               Enum.sort(Horde.Registry.keys(horde, self()))

      :ok =
        Horde.Registry.unregister_match(
          horde,
          "another_key",
          [value: :"$1"],
          [{:>, :"$1", 11}]
        )

      assert ["to_unregister"] = Horde.Registry.keys(horde, self())

      :ok =
        Horde.Registry.unregister_match(
          horde,
          "to_unregister",
          "doesn't match"
        )

      assert [{self(), "match_unregister"}] ==
               Horde.Registry.lookup(horde, "to_unregister")

      assert ["to_unregister"] = Horde.Registry.keys(horde, self())

      :ok =
        Horde.Registry.unregister_match(
          horde,
          "to_unregister",
          "match_unregister"
        )

      Process.sleep(200)

      assert :undefined = Horde.Registry.lookup(horde, "to_unregister")
      assert [] = Horde.Registry.keys(horde, self())
    end
  end

  describe ".dispatch/4" do
    test "dispatches to correct processes" do
      horde = start_registry()

      Horde.Registry.register(horde, "d1", "value1")
      Horde.Registry.register(horde, "d2", "value2")

      assert :ok =
               Horde.Registry.dispatch(horde, "d1", fn [{pid, value}] ->
                 send(pid, {:value, value})
               end)

      assert_received({:value, "value1"})

      defmodule TestSender do
        def send([{pid, value}]), do: Kernel.send(pid, {:value, value})
      end

      assert :ok = Horde.Registry.dispatch(horde, "d2", {TestSender, :send, []})

      assert_received({:value, "value2"})
    end
  end

  describe ".count/1" do
    test "returns correct number" do
      horde = start_registry()

      Horde.Registry.register(horde, "foo", "foo")
      Horde.Registry.register(horde, "bar", "bar")
      assert 2 = Horde.Registry.count(horde)
    end
  end

  describe ".count_match/4" do
    test "returns correct number" do
      horde = start_registry()

      Horde.Registry.register(horde, "foo", "foo")
      Horde.Registry.register(horde, "bar", bar: 33)

      assert 1 = Horde.Registry.count_match(horde, "foo", :_)
      assert 0 = Horde.Registry.count_match(horde, "bar", bar: 34)
      assert 1 = Horde.Registry.count_match(horde, "bar", bar: 33)

      assert 0 =
               Horde.Registry.count_match(horde, "bar", [bar: :"$1"], [
                 {:>, :"$1", 34}
               ])

      assert 1 =
               Horde.Registry.count_match(horde, "bar", [bar: :"$1"], [
                 {:>, :"$1", 32}
               ])
    end
  end

  describe ".match/4" do
    test "returns correct pids / values" do
      {:ok, _} = Horde.Registry.start_link(name: :match_horde, keys: :unique)

      Horde.Registry.register(:match_horde, "foo", "foo")
      Horde.Registry.register(:match_horde, "bar", bar: 33)

      self = self()
      assert [{^self, "foo"}] = Horde.Registry.match(:match_horde, "foo", :_)
      assert [] = Horde.Registry.match(:match_horde, "bar", bar: 34)
      assert [{^self, bar: 33}] = Horde.Registry.match(:match_horde, "bar", bar: 33)

      assert [] =
               Horde.Registry.match(:match_horde, "bar", [bar: :"$1"], [
                 {:>, :"$1", 34}
               ])

      assert [{^self, bar: 33}] =
               Horde.Registry.match(:match_horde, "bar", [bar: :"$1"], [
                 {:>, :"$1", 32}
               ])
    end
  end

  describe ".update_value/3" do
    test "updates value" do
      {:ok, _} = Horde.Registry.start_link(name: :update_value_horde, keys: :unique)
      Horde.Registry.register(:update_value_horde, "foo", "foo")

      assert {"bar", "foo"} =
               Horde.Registry.update_value(:update_value_horde, "foo", fn "foo" -> "bar" end)

      pid = self()

      Process.sleep(200)

      assert [{^pid, "bar"}] = Horde.Registry.lookup(:update_value_horde, "foo")
    end

    test "can only update own values" do
      {:ok, _} = Horde.Registry.start_link(name: :update_value_horde2, keys: :unique)

      Task.start_link(fn ->
        Horde.Registry.register(:update_value_horde2, "foo", "bar")
        Process.sleep(200)
      end)

      Process.sleep(20)

      assert :error =
               Horde.Registry.update_value(:update_value_horde2, "foo", fn _old -> "baz" end)
    end
  end

  describe "lookup" do
    test "existing process with lookup/2" do
      horde = Horde.Registry.ClusterB
      {:ok, _horde} = Horde.Registry.start_link(name: horde, keys: :unique)

      Horde.Registry.register(horde, :carmen, "foo")

      assert [{self(), "foo"}] == Horde.Registry.lookup(horde, :carmen)
    end

    test "existing processes with via tuple" do
      horde = Horde.Registry.ClusterC
      {:ok, _horde} = Horde.Registry.start_link(name: horde, keys: :unique)

      Horde.Registry.register(horde, :carmen, "bar")

      name = {:via, Horde.Registry, {horde, :carmen}}
      assert [{self(), "bar"}] == Horde.Registry.lookup(name)
    end
  end

  describe "sending messages" do
    test "sending message to non-existing process" do
      horde = Horde.Registry.ClusterD
      {:ok, _horde} = Horde.Registry.start_link(name: horde, keys: :unique)
      Horde.Registry.register(horde, :carmen, "carmen")

      assert_raise ArgumentError, fn ->
        Horde.Registry.send({horde, :santiago}, "Where are you?")
      end
    end

    test "sending message to non-existing horde" do
      horde = Horde.Registry.ClusterE
      {:ok, _horde} = Horde.Registry.start_link(name: horde, keys: :unique)

      spawn(fn ->
        Horde.Registry.register(horde, :carmen, "carmen")
        Process.sleep(300)
      end)

      Process.sleep(20)

      assert_raise ArgumentError, fn ->
        Horde.Registry.send({Horde.Registry.DoesNotExist, :santiago}, "Where are you?")
      end
    end

    test "sending message to existing process" do
      horde = Horde.Registry.ClusterF
      {:ok, _horde} = Horde.Registry.start_link(name: horde, keys: :unique)

      spawn(fn ->
        Horde.Registry.register(horde, :carmen, "carmen")
        Process.sleep(300)
      end)

      Process.sleep(20)

      assert "Where are you?" = Horde.Registry.send({horde, :carmen}, "Where are you?")
    end
  end

  describe ".meta/2 and .put_meta/3" do
    test "can set meta in start_link/3" do
      registry = Horde.Registry.ClusterH

      {:ok, _horde} =
        Horde.Registry.start_link(name: registry, keys: :unique, meta: [meta_key: :meta_value])

      assert {:ok, :meta_value} = Horde.Registry.meta(registry, :meta_key)
    end

    test "can put and get metadata" do
      registry = Horde.Registry.ClusterG
      {:ok, _horde} = Horde.Registry.start_link(name: registry, keys: :unique)
      :ok = Horde.Registry.put_meta(registry, :custom_key, "custom_value")

      assert {:ok, "custom_value"} = Horde.Registry.meta(registry, :custom_key)
    end

    test "meta/2 returns :error when no entry present" do
      registry = Horde.Registry.ClusterI
      {:ok, _horde} = Horde.Registry.start_link(name: registry, keys: :unique)
      :ok = Horde.Registry.put_meta(registry, :custom_key, "custom_value")

      assert :error = Horde.Registry.meta(registry, :non_existant)
    end

    test "meta is propagated" do
      r1 = Horde.Registry.PropagateMeta1
      r2 = Horde.Registry.PropagateMeta2
      {:ok, _horde} = Horde.Registry.start_link(name: r1, keys: :unique)
      {:ok, _horde} = Horde.Registry.start_link(name: r2, keys: :unique)
      Horde.Cluster.set_members(r1, [r1, r2])
      Horde.Registry.put_meta(r1, :a_key, "a_value")
      Process.sleep(200)
      assert {:ok, "a_value"} = Horde.Registry.meta(r2, :a_key)
    end
  end

  describe "failure scenarios" do
    test "a process exits and is cleaned up" do
      registry = Horde.Registry.ClusterJ
      {:ok, _} = Horde.Registry.start_link(name: registry, keys: :unique)

      %{pid: pid} =
        Task.async(fn ->
          Horde.Registry.register(registry, "key", nil)
          Process.sleep(100)
        end)

      Process.sleep(60)
      assert [{^pid, nil}] = Horde.Registry.lookup(registry, "key")
      assert 1 = Horde.Registry.count_match(registry, "key", :_)

      Process.sleep(100)
      assert 0 = Horde.Registry.count_match(registry, "key", :_)

      assert [] = Horde.Registry.keys(registry, pid)
    end

    test "a node is removed from the cluster and its processes are cleaned up" do
      reg1 = Horde.Registry.ClusterK
      reg2 = Horde.Registry.ClusterL
      {:ok, _} = Horde.Registry.start_link(name: reg1, keys: :unique, members: [reg1, reg2])
      {:ok, _} = Horde.Registry.start_link(name: reg2, keys: :unique)

      %{pid: pid} =
        Task.async(fn ->
          Horde.Registry.register(reg1, "key", nil)
          Process.sleep(400)
        end)

      Process.sleep(200)

      assert [{^pid, nil}] = Horde.Registry.lookup(reg1, "key")
      assert [{^pid, nil}] = Horde.Registry.lookup(reg2, "key")

      Horde.Cluster.set_members(reg2, [reg2])

      assert :undefined = Horde.Registry.lookup(reg2, "key")
    end
  end

  defp register_task(registry, key, value) do
    parent = self()

    {:ok, task} =
      Task.start(fn ->
        send(parent, Horde.Registry.register(registry, key, value))
        Process.sleep(:infinity)
      end)

    assert_receive {:ok, owner}
    {owner, task}
  end

  defp start_registry(opts \\ [keys: :unique]) do
    horde = :"h#{-:erlang.monotonic_time()}"
    {:ok, _pid} = Horde.Registry.start_link([name: horde] ++ opts)

    horde
  end
end
