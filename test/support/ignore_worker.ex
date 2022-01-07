defmodule IgnoreWorker do
  require Logger

  def child_spec(name) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [name]}}
  end

  def start_link(name) do
    case GenServer.start_link(__MODULE__, nil, name: name) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        Logger.error(
          "#{__MODULE__} already started! local node is #{node()}, registered pid is #{inspect(pid)}, returning :ignore"
        )

        :ignore
    end
  end

  def init(nil) do
    Logger.info("#{__MODULE__} started on node #{node()}.")
    {:ok, nil}
  end
end
