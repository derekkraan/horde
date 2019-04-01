defmodule StressTest do
  use GenServer
  require Logger

  def perform(number, seconds_to_live), do: start_link({number, seconds_to_live})

  def start_link({number, seconds_to_live}) do
    GenServer.start_link(__MODULE__, {number, seconds_to_live})
  end

  def init({number, seconds_to_live}) do
    IO.inspect("#{number}")
    {:ok, {number, seconds_to_live}, {:continue, :start_processes}}
  end

  def handle_continue(:start_processes, {0, _}) do
    {:stop, :normal, nil}
  end

  def handle_continue(:start_processes, {number, seconds_to_live}) do
    Horde.Supervisor.start_child(HelloWorld.HelloSupervisor, %{
      id: number,
      restart: :transient,
      start: {
        Task,
        :start_link,
        [
          fn ->
            Horde.Registry.register(HelloWorld.HelloRegistry, number, nil)
            Process.sleep(seconds_to_live * 1000)
            Logger.info("process #{number} finished")
          end
        ]
      }
    })

    Logger.info("started process #{number}")

    {:noreply, {number - 1, seconds_to_live}, {:continue, :start_processes}}
  end
end
