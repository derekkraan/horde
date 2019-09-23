defmodule Horde.DynamicSupervisorImpl.Rebalancer do
  use GenServer

  require Logger

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name])
  end

  @impl true
  def init(opts) do
    {:ok, nil}
  end

  @impl true
  def handle_info({:rebalance, dsi_state, from}, state) do
    cspec_by_pid = Map.values(dsi_state.processes_by_id) |>
      Enum.reduce(%{}, fn({_, cspec, pid}, acc) ->
        Map.put(acc, pid, cspec)
      end)

    member_by_pid = Map.values(dsi_state.processes_by_id) |>
      Enum.reduce(%{}, fn({member, _, pid}, acc) ->
        Map.put(acc, pid, member)
      end)

    rebalanced = member_by_pid |> 
      Map.keys() |>
      Enum.map(fn(pid) ->
        child_spec = Map.get(cspec_by_pid, pid)
        identifier = :erlang.phash2(Map.drop(child_spec, [:id]))

        {:ok, %Horde.DynamicSupervisor.Member{name: new_member}} = dsi_state.distribution_strategy.choose_node(identifier, Map.values(dsi_state.members_info))

        current_member = Map.get(member_by_pid, pid, nil)

        case (current_member == new_member) do
          false ->
            %{start: {_, _, [[{:name, name} | _]]}} = child_spec

            Logger.info("Redistributing node: #{Kernel.inspect(pid)} | #{Kernel.inspect(current_member)} -> #{Kernel.inspect(new_member)} | #{Kernel.inspect(name)}")

            case Horde.DynamicSupervisor.terminate_child(dsi_state.name, pid) do
              :ok ->
                {:ok, _} = Horde.DynamicSupervisor.start_child(dsi_state.name, child_spec)
              {:error, :not_found} ->
                Logger.error("Error redistributing #{Kernel.inspect(pid)} to node #{Kernel.inspect(new_member)}: process not found (likely already terminated).")
              {:error, {:node_dead_or_shutting_down, msg}} ->
                Logger.error("Error redistributing #{Kernel.inspect(pid)} to node #{Kernel.inspect(new_member)}: #{msg}")
            end

            {pid, [{:child_spec, child_spec}, {:from, current_member}, {:to, new_member}]}
          true ->
            {pid, :unchanged}
        end

      end) |>
      Enum.filter(fn({_, status}) ->
        status != :unchanged
      end) |>
      Enum.into(%{})

    GenServer.reply(from, {:ok, rebalanced})
    {:noreply, state}
  end
end

