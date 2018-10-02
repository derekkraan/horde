defmodule Horde.ProcessSupervisor do
  @moduledoc false

  use Supervisor

  def child_spec({child_spec, graceful_shutdown_manager, node_id}) do
    %{
      id: child_spec.id,
      start: {__MODULE__, :start_link, [child_spec, graceful_shutdown_manager, node_id]},
      type: :supervisor
    }
  end

  def start_link(child_spec, graceful_shutdown_manager, node_id) do
    Supervisor.start_link(
      __MODULE__,
      {child_spec, graceful_shutdown_manager},
      name: name(node_id, child_spec.id)
    )
  end

  def name(node_id, child_id) do
    :"#{__MODULE__}.#{Base.encode16(node_id)}.#{term_to_string_identifier(child_id)}"
  end

  def init({child_spec, graceful_shutdown_manager}) do
    children = [
      {Horde.ProcessCanary, {child_spec, graceful_shutdown_manager}}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp term_to_string_identifier(term), do: term |> :erlang.term_to_binary() |> Base.encode16()
end
