defmodule Horde.ProcessSupervisor do
  @moduledoc false

  use Supervisor

  def child_spec({child_spec, graceful_shutdown_manager, node_id, options}) do
    %{
      id: child_spec.id,
      start: {__MODULE__, :start_link, [child_spec, graceful_shutdown_manager, node_id, options]},
      type: :supervisor
    }
  end

  def start_link(child_spec, graceful_shutdown_manager, node_id, options) do
    Supervisor.start_link(
      __MODULE__,
      {child_spec, graceful_shutdown_manager, options},
      name: name(node_id, child_spec.id)
    )
  end

  def name(node_id, child_id) do
    :"#{__MODULE__}.#{Base.encode16(node_id)}.#{term_to_string_identifier(child_id)}"
  end

  def init({child_spec, graceful_shutdown_manager, options}) do
    options = Keyword.put(options, :strategy, :one_for_one)

    children = [
      {Horde.ProcessCanary, {child_spec, graceful_shutdown_manager}}
    ]

    Supervisor.init(children, options)
  end

  defp term_to_string_identifier(term), do: term |> :erlang.term_to_binary() |> Base.encode16()
end
