defmodule Horde.DynamicSupervisorTelemetryPoller do
  @moduledoc false

  require Logger

  def child_spec(supervisor_impl_name) do
    %{
      id: :"#{supervisor_impl_name}_telemetry_poller",
      start: {
        :telemetry_poller,
        :start_link,
        [
          [
            measurements: [
              {:process_info,
               name: supervisor_impl_name,
               event: [:horde, :supervisor],
               keys: [:message_queue_len]},
              {__MODULE__, :poll, [supervisor_impl_name]}
            ],
            period: 5_000,
            name: :"#{supervisor_impl_name}_telemetry_poller"
          ]
        ]
      }
    }
  end

  def poll(supervisor_impl_name) do
    metrics = GenServer.call(supervisor_impl_name, :get_telemetry)

    :telemetry.execute([:horde, :supervisor, :supervised_process_count], metrics, %{
      name: supervisor_impl_name
    })
  catch
    :exit, reason ->
      Logger.warn("""
      Exit while fetching metrics from #{inspect(supervisor_impl_name)}.
      Skip poll action. Reason: #{inspect(reason)}.
      """)

      :ok
  end
end
