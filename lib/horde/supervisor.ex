defmodule Horde.Supervisor do
  @moduledoc """
  A distributed supervisor.

  Horde.Supervisor implements a distributed DynamicSupervisor backed by a add-wins last-write-wins δ-CRDT (provided by `DeltaCrdt.AWLWWMap`). This CRDT is used for both tracking membership of the cluster and tracking supervised processes.

  Using CRDTs guarantees that the distributed, shared state will eventually converge. It also means that Horde.Supervisor is eventually-consistent, and is optimized for availability and partition tolerance. This can result in temporary inconsistencies under certain conditions (when cluster membership is changing, for example).

  Cluster membership is managed with `Horde.Cluster`. Joining a cluster can be done with `Horde.Cluster.set_members/2`. To take a node out of the cluster, call `Horde.Cluster.set_members/2` without that node in the list.

  Each Horde.Supervisor node wraps its own local instance of `DynamicSupervisor`. `Horde.Supervisor.start_child/2` (for example) delegates to the local instance of DynamicSupervisor to actually start and monitor the child. The child spec is also written into the processes CRDT, along with a reference to the node on which it is running. When there is an update to the processes CRDT, Horde makes a comparison and corrects any inconsistencies (for example, if a conflict has been resolved and there is a process that no longer should be running on its node, it will kill that process and remove it from the local supervisor). So while most functions map 1:1 to the equivalent DynamicSupervisor functions, the eventually consistent nature of Horde requires extra behaviour not present in DynamicSupervisor.

  ## Divergence from standard DynamicSupervisor behaviour

  While Horde wraps DynamicSupervisor, it does keep track of processes by the `id` in the child specification. This is a divergence from the behaviour of DynamicSupervisor, which ignores ids altogether. Using DynamicSupervisor is useful for its shutdown behaviour (it shuts down all child processes simultaneously, unlike `Supervisor`).

  ## Graceful shutdown

  When a node is stopped (either manually or by calling `:init.stop`), Horde restarts the child processes of the stopped node on another node. The state of child processes is not preserved, they are simply restarted.

  To implement graceful shutdown of worker processes, a few extra steps are necessary.

  1. Trap exits. Running `Process.flag(:trap_exit)` in the `init/1` callback of any `worker` processes will convert exit signals to messages and allow running `terminate/2` callbacks. It is also important to include the `shutdown` option in your child spec (the default is 5000ms).

  2. Use `:init.stop()` to shut down your node. How you accomplish this is up to you, but by simply calling `:init.stop()` somewhere, graceful shutdown will be triggered.

  ## Module-based Supervisor

  Horde supports module-based supervisors to enable dynamic runtime configuration.

  ```elixir
  defmodule MySupervisor do
    use Horde.Supervisor

    def init(options) do
      {:ok, Keyword.put(options, :members, get_members())}
    end

    defp get_members() do
      # ...
    end
  end
  ```

  Then you can use `MySupervisor.child_spec/1` and `MySupervisor.start_link/1` in the same way as you'd use `Horde.Supervisor.child_spec/1` and `Horde.Supervisor.start_link/1`.
  """

  defmacro __using__(_opts) do
    quote do
      @behaviour Horde.Supervisor

      def child_spec(options) do
        options = Keyword.put_new(options, :id, __MODULE__)

        %{
          id: Keyword.get(options, :id, __MODULE__),
          start: {__MODULE__, :start_link, [options]},
          type: :supervisor
        }
      end

      def start_link(options) do
        Horde.Supervisor.start_link(Keyword.put(options, :init_module, __MODULE__))
      end
    end
  end

  @callback init(options()) :: {:ok, options()}

  @doc """
  See `start_link/2` for options.
  """
  @spec child_spec(options :: options()) :: Supervisor.child_spec()
  def child_spec(options \\ []) do
    supervisor_options =
      Keyword.take(options, [
        :name,
        :strategy,
        :max_restarts,
        :max_seconds,
        :max_children,
        :extra_arguments,
        :distribution_strategy,
        :shutdown,
        :members
      ])

    options = Keyword.take(options, [:id, :restart, :shutdown, :type])

    %{
      id: Keyword.get(options, :id, __MODULE__),
      start: {__MODULE__, :start_link, [supervisor_options]},
      type: :supervisor,
      shutdown: Keyword.get(options, :shutdown, :infinity)
    }
    |> Supervisor.child_spec(options)
  end

  @type options() :: [option()]
  @type option ::
          {:name, name :: atom()}
          | {:strategy, Supervisor.strategy()}
          | {:max_restarts, integer()}
          | {:max_seconds, integer()}
          | {:extra_arguments, [term()]}
          | {:distribution_strategy, Horde.DistributionStrategy.t()}
          | {:shutdown, integer()}
          | {:members, [Horde.Cluster.member()]}

  @doc """
  Works like `DynamicSupervisor.start_link/1`. Extra options are documented here:
  - `:distribution_strategy`, defaults to `Horde.UniformDistribution` but can also be set to `Horde.UniformQuorumDistribution`. `Horde.UniformQuorumDistribution` enforces a quorum and will shut down all processes on a node if it is split from the rest of the cluster.
  """
  def start_link(options) do
    root_name = Keyword.get(options, :name, nil)

    if is_nil(root_name) do
      raise "must specify :name in options, got: #{inspect(options)}"
    end

    options = Keyword.put_new(options, :members, [root_name])

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

  Works like `DynamicSupervisor.terminate_child/2`.
  """
  @spec terminate_child(Supervisor.supervisor(), child_pid :: pid()) :: :ok | {:error, :not_found}
  def terminate_child(supervisor, child_pid), do: call(supervisor, {:terminate_child, child_pid})

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

  @doc """
  Waits for Horde.Supervisor to have quorum.
  """
  @spec wait_for_quorum(horde :: GenServer.server(), timeout :: timeout()) :: :ok
  def wait_for_quorum(horde, timeout) do
    GenServer.call(horde, :wait_for_quorum, timeout)
  end

  defp call(supervisor, msg), do: GenServer.call(supervisor, msg, :infinity)
end
