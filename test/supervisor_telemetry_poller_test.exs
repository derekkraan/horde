defmodule SupervisorTelemetryPollerTest do
  @moduledoc false

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Horde.DynamicSupervisorTelemetryPoller, as: Poller

  # Just a dummy GenServer to mock Supervisor.
  defmodule SupervisorMock do
    use GenServer

    def init(_), do: {:ok, %{}}

    def handle_call(:get_telemetry, _, state), do: {:reply, %{metrics: 1}, state}
  end

  setup do
    {:ok, pid} = GenServer.start_link(SupervisorMock, %{test_case: :exit}, name: SupervisorMock)
    Process.unlink(pid)

    on_exit(fn -> Process.alive?(pid) && GenServer.stop(pid) end)
  end

  describe "when polls supervisors metrics with success" do
    test "it sends metrics to telemetry" do
      assert Poller.poll(SupervisorMock) == :ok
    end
  end

  describe "when fails to poll supervisors metrics" do
    test "it handles exit and logs reason" do
      assert capture_log(fn -> :ok = Poller.poll(nil) end) =~ "Exit while fetching metrics from"
    end
  end
end
