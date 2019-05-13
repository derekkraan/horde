defmodule LocalClusterHelper do
  def start(m, f, a) do
    :erlang.apply(m, f, a)

    receive do
    end
  end

  def send_msg(pid, msg) do
    fn -> send(pid, msg) end
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
