defmodule Horde.Supervisor do
  @moduledoc """
  A distributed supervisor.

  Horde.Supervisor implements a distributed DynamicSupervisor backed by a add-wins last-write-wins δ-CRDT (provided by `DeltaCrdt.AWLWWMap`). This CRDT is used for both tracking membership of the cluster and tracking supervised processes.

  Using CRDTs guarantees that the distributed, shared state will eventually converge. It also means that Horde.Supervisor is eventually-consistent, and is optimized for availability and partition tolerance. This can result in temporary inconsistencies under certain conditions (when cluster membership is changing, for example).

  Cluster membership is managed with `Horde.Cluster`. Joining a cluster can be done with `Horde.Cluster.join_hordes/2` and leaving a cluster happens automatically when you stop the supervisor with `Horde.Supervisor.stop/3`.

  Each Horde.Supervisor node wraps its own local instance of `DynamicSupervisor`. `Horde.Supervisor.start_child/2` (for example) delegates to the local instance of DynamicSupervisor to actually start and monitor the child. The child spec is also written into the processes CRDT, along with a reference to the node on which it is running. When there is an update to the processes CRDT, Horde makes a comparison and corrects any inconsistencies (for example, if a conflict has been resolved and there is a process that no longer should be running on its node, it will kill that process and remove it from the local supervisor). So while most functions map 1:1 to the equivalent DynamicSupervisor functions, the eventually consistent nature of Horde requires extra behaviour not present in DynamicSupervisor.

  ## Divergence from standard DynamicSupervisor behaviour

  While Horde wraps DynamicSupervisor, it does keep track of processes by the `id` in the child specification. This is a divergence from the behaviour of DynamicSupervisor, which ignores ids altogether. Using DynamicSupervisor is useful for its shutdown behaviour (it shuts down all child processes simultaneously, unlike `Supervisor`).

  ## Graceful shutdown

  When a node is stopped (either manually or by calling `:init.stop`), Horde restarts the child processes of the stopped node on another node. The state of child processes is not preserved, they are simply restarted.

  To implement graceful shutdown of worker processes, a few extra steps are necessary.

  1. Trap exits. Running `Process.flag(:trap_exit)` in the `init/1` callback of any `worker` processes will convert exit signals to messages and allow running `terminate/2` callbacks. It is also important to include the `shutdown` option in your child spec (the default is 5000ms).

  2. Use `:init.stop()` to shut down your node. How you accomplish this is up to you, but by simply calling `:init.stop()` somewhere, graceful shutdown will be triggered.
  """

  @doc """
  See `start_link/2` for options.
  """
  def child_spec(options \\ []) do
    options = Keyword.put_new(options, :id, __MODULE__)

    %{
      id: options[:id],
      start: {__MODULE__, :start_link, [Keyword.drop(options, [:id])]},
      type: :supervisor
    }
  end

  @doc """
  Works like `DynamicSupervisor.start_link/1`. Extra options are documented here:
  - `:distribution_strategy`, defaults to `Horde.UniformDistribution` but can also be set to `Horde.UniformQuorumDistribution`. `Horde.UniformQuorumDistribution` enforces a quorum and will shut down all processes on a node if it is split from the rest of the cluster.
  """
  def start_link(options) do
    root_name = Keyword.get(options, :name, nil)

    if is_nil(root_name) do
      raise "must specify :name in options, got: #{inspect(options)}"
    end

    options = Keyword.put(options, :root_name, root_name)

    Supervisor.start_link(Horde.SupervisorSupervisor, options, name: :"#{root_name}.Supervisor")
  end

  @doc """
  Works like `DynamicSupervisor.stop/3`.
  """
  def stop(supervisor, reason \\ :normal, timeout \\ :infinity),
    do: Supervisor.stop(:"#{supervisor}.Supervisor", reason, timeout)

  @doc """
  Works like `DynamicSupervisor.start_child/2`.
  """
  def start_child(supervisor, child_spec) do
    child_spec = Supervisor.child_spec(child_spec, [])
    call(supervisor, {:start_child, child_spec})
  end

  @doc """
  Terminate a child process.

  Unlike `DynamicSupervisor.terminate_child/2`, this function expects a child_id, and not a pid.
  """
  @spec terminate_child(Supervisor.supervisor(), child_id :: term()) :: :ok | {:error, :not_found}
  def terminate_child(supervisor, child_id), do: call(supervisor, {:terminate_child, child_id})

  @doc """
  Works like `DynamicSupervisor.which_children/1`.

  This function delegates to all supervisors in the cluster and returns the aggregated output. Where memory warnings apply to `DynamicSupervisor.which_children`, these count double for `Horde.Supervisor.which_children`.
  """
  def which_children(supervisor), do: call(supervisor, :which_children)

  @doc """
  Works like `DynamicSupervisor.count_children/1`.

  This function delegates to all supervisors in the cluster and returns the aggregated output.
  """
  def count_children(supervisor), do: call(supervisor, :count_children)

  defp call(supervisor, msg), do: GenServer.call(supervisor, msg, :infinity)
end
