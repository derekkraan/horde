defmodule StressTest do
  use GenServer
  require Logger

  def perform(number, seconds_to_live), do: start_link({number, seconds_to_live})

  def start_link({number, seconds_to_live}) do
    GenServer.start_link(__MODULE__, {number, seconds_to_live})
  end

  def init({number, seconds_to_live}) do
    {:ok, {number, seconds_to_live}, {:continue, :start_processes}}
  end

  def handle_continue(:start_processes, {0, _}) do
    {:stop, :normal, nil}
  end

  def handle_continue(:start_processes, {number, seconds_to_live}) do
    seconds_with_jitter =
      (seconds_to_live * 0.75 + :rand.uniform(seconds_to_live) / 2)
      |> round()

    Horde.Supervisor.start_child(HelloWorld.HelloSupervisor, %{
      id: number,
      restart: :transient,
      start: {
        Task,
        :start_link,
        [
          fn ->
            Horde.Registry.register(HelloWorld.HelloRegistry, number, nil)
            Process.sleep(seconds_with_jitter * 1000)
            Logger.info("process #{number} finished after #{seconds_with_jitter}s")
          end
        ]
      }
    })

    Logger.info("started process #{number}")

    {:noreply, {number - 1, seconds_to_live}, {:continue, :start_processes}}
  end
end
