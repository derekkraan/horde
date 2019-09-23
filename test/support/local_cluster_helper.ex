defmodule LocalClusterHelper do
  def start(m, f, a) do
    :erlang.apply(m, f, a)

    receive do
    end
  end

  def send_msg(pid, msg) do
    fn -> send(pid, msg) end
  end

  def await_members_alive(sup_name) do
    # get members_info from the DyanamicSupervisorImpl n1 state
    ds_state = :sys.get_state(Process.whereis(sup_name))

    # check that state is :alive for all nodes
    all_alive =
      ds_state.members_info
      |> Map.values()
      |> Enum.all?(fn mem ->
        mem.status == :alive
      end)

    case all_alive do
      false ->
        # sleep 100ms and try again
        :timer.sleep(100)
        await_members_alive(sup_name)

      true ->
        ds_state
    end
  end
end

defmodule EchoServer do
  def start_link(pid) do
    GenServer.start_link(__MODULE__, pid)
  end

  # def via_tuple do
  #   {:via, Horde.Registry, {:horde_registry, "echo"}}
  # end

  def init(pid) do
    send(self(), :do_send)
    {:ok, pid}
  end

  def handle_info(:do_send, pid) do
    send(pid, {node(), :hello_echo_server})
    Process.send_after(self(), :do_send, 1_000)
    {:noreply, pid}
  end
end
