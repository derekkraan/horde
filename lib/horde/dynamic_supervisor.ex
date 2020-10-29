defmodule Horde.DynamicSupervisor do
  @moduledoc """
  A distributed supervisor.

  Horde.DynamicSupervisor implements a distributed DynamicSupervisor backed by a add-wins last-write-wins δ-CRDT (provided by `DeltaCrdt.AWLWWMap`). This CRDT is used for both tracking membership of the cluster and tracking supervised processes.

  Using CRDTs guarantees that the distributed, shared state will eventually converge. It also means that Horde.DynamicSupervisor is eventually-consistent, and is optimized for availability and partition tolerance. This can result in temporary inconsistencies under certain conditions (when cluster membership is changing, for example).

  Cluster membership is managed with `Horde.Cluster`. Joining a cluster can be done with `Horde.Cluster.set_members/2`. To take a node out of the cluster, call `Horde.Cluster.set_members/2` without that node in the list. Alternatively, setting the `members` startup option to `:auto` will make Horde auto-manage cluster membership so that all (and only) visible nodes are members of the cluster.

  Each Horde.DynamicSupervisor node wraps its own local instance of `DynamicSupervisor`. `Horde.DynamicSupervisor.start_child/2` (for example) delegates to the local instance of DynamicSupervisor to actually start and monitor the child. The child spec is also written into the processes CRDT, along with a reference to the node on which it is running. When there is an update to the processes CRDT, Horde makes a comparison and corrects any inconsistencies (for example, if a conflict has been resolved and there is a process that no longer should be running on its node, it will kill that process and remove it from the local supervisor). So while most functions map 1:1 to the equivalent DynamicSupervisor functions, the eventually consistent nature of Horde requires extra behaviour not present in DynamicSupervisor.

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
    use Horde.DynamicSupervisor

    def start_link(init_arg, options \\ []) do
      Horde.DynamicSupervisor.start_link(__MODULE__, init_arg, options)
    end

    def init(init_arg) do
      [strategy: :one_for_one, members: members()]
      |> Keyword.merge(init_arg)
      |> Horde.DynamicSupervisor.init()
    end

    defp members() do
      []
    end
  end
  ```

  Then you can use `MySupervisor.child_spec/1` and `MySupervisor.start_link/1` in the same way as you'd use `Horde.DynamicSupervisor.child_spec/1` and `Horde.DynamicSupervisor.start_link/1`.
  """
  use Supervisor

  @type options() :: [option()]
  @type option ::
          {:name, name :: atom()}
          | {:strategy, Supervisor.strategy()}
          | {:max_restarts, integer()}
          | {:max_seconds, integer()}
          | {:extra_arguments, [term()]}
          | {:distribution_strategy, Horde.DistributionStrategy.t()}
          | {:shutdown, integer()}
          | {:members, [Horde.Cluster.member()] | :auto}
          | {:delta_crdt_options, [DeltaCrdt.crdt_option()]}
          | {:process_redistribution, :active | :passive}

  @callback init(options()) :: {:ok, options()} | :ignore
  @callback child_spec(options :: options()) :: Supervisor.child_spec()

  defmacro __using__(options) do
    quote location: :keep, bind_quoted: [options: options] do
      @behaviour Horde.DynamicSupervisor
      if Module.get_attribute(__MODULE__, :doc) == nil do
        @doc """
        Returns a specification to start this module under a supervisor.
        See `Supervisor`.
        """
      end

      @impl true
      def child_spec(arg) do
        default = %{
          id: __MODULE__,
          start: {__MODULE__, :start_link, [arg]},
          type: :supervisor
        }

        Supervisor.child_spec(default, unquote(Macro.escape(options)))
      end

      defoverridable child_spec: 1
    end
  end

  @doc """
  See `start_link/2` for options.
  """
  def child_spec(options) when is_list(options) do
    id = Keyword.get(options, :name, Horde.DynamicSupervisor)

    %{
      id: id,
      start: {Horde.DynamicSupervisor, :start_link, [options]},
      type: :supervisor
    }
  end

  @doc """
  Works like `DynamicSupervisor.start_link/1`. Extra options are documented here:
  - `:distribution_strategy`, defaults to `Horde.UniformDistribution` but can also be set to `Horde.UniformQuorumDistribution`. `Horde.UniformQuorumDistribution` enforces a quorum and will shut down all processes on a node if it is split from the rest of the cluster.
  """
  def start_link(options) when is_list(options) do
    keys = [
      :extra_arguments,
      :max_children,
      :max_seconds,
      :max_restarts,
      :strategy,
      :distribution_strategy,
      :process_redistribution,
      :members,
      :delta_crdt_options
    ]

    {sup_options, start_options} = Keyword.split(options, keys)
    start_link(Supervisor.Default, init(sup_options), start_options)
  end

  def start_link(mod, init_arg, opts \\ []) do
    name = :"#{opts[:name]}.Supervisor"
    start_options = Keyword.put(opts, :name, name)
    Supervisor.start_link(__MODULE__, {mod, init_arg, opts[:name]}, start_options)
  end

  @doc """
  Works like `DynamicSupervisor.init/1`.
  """
  def init(options) when is_list(options) do
    unless strategy = options[:strategy] do
      raise ArgumentError, "expected :strategy option to be given"
    end

    max_restarts = Keyword.get(options, :max_restarts, 3)
    max_seconds = Keyword.get(options, :max_seconds, 5)
    max_children = Keyword.get(options, :max_children, :infinity)
    extra_arguments = Keyword.get(options, :extra_arguments, [])
    members = Keyword.get(options, :members, [])
    delta_crdt_options = Keyword.get(options, :delta_crdt_options, [])
    process_redistribution = Keyword.get(options, :process_redistribution, :passive)

    distribution_strategy =
      Keyword.get(
        options,
        :distribution_strategy,
        Horde.UniformDistribution
      )

    flags = %{
      strategy: strategy,
      max_restarts: max_restarts,
      max_seconds: max_seconds,
      max_children: max_children,
      extra_arguments: extra_arguments,
      distribution_strategy: distribution_strategy,
      members: members,
      delta_crdt_options: delta_crdt_options(delta_crdt_options),
      process_redistribution: process_redistribution
    }

    {:ok, flags}
  end

  def init({mod, init_arg, name}) do
    case mod.init(init_arg) do
      {:ok, flags} when is_map(flags) ->
        [
          {DeltaCrdt,
           [
             sync_interval: flags.delta_crdt_options.sync_interval,
             max_sync_size: flags.delta_crdt_options.max_sync_size,
             shutdown: flags.delta_crdt_options.shutdown,
             crdt: DeltaCrdt.AWLWWMap,
             on_diffs: {Horde.DynamicSupervisorImpl, :on_diffs, [name]},
             name: crdt_name(name)
           ]},
          {Horde.DynamicSupervisorImpl,
           [
             name: name,
             root_name: name,
             init_module: mod,
             strategy: flags.strategy,
             intensity: flags.max_restarts,
             period: flags.max_seconds,
             max_children: flags.max_children,
             extra_arguments: flags.extra_arguments,
             distribution_strategy: flags.distribution_strategy,
             process_redistribution: flags.process_redistribution,
             members: members(flags.members, name)
           ]},
          {Horde.ProcessesSupervisor,
           [
             shutdown: :infinity,
             root_name: name,
             type: :supervisor,
             name: supervisor_name(name),
             strategy: flags.strategy,
             max_restarts: flags.max_restarts,
             max_seconds: flags.max_seconds
           ]},
          {Horde.SignalShutdown,
           [
             signal_to: [name]
           ]},
          {Horde.DynamicSupervisorTelemetryPoller, name}
        ]
        |> maybe_add_node_manager(flags.members, name)
        |> Supervisor.init(strategy: :one_for_all, max_restarts: 0)

      :ignore ->
        :ignore

      other ->
        {:stop, {:bad_return, {mod, :init, other}}}
    end
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
  @spec terminate_child(Supervisor.supervisor(), child_pid :: pid()) ::
          :ok | {:error, :not_found} | {:error, {:node_dead_or_shutting_down, String.t()}}
  def terminate_child(supervisor, child_pid) when is_pid(child_pid),
    do: call(supervisor, {:terminate_child, child_pid})

  @doc """
  Works like `DynamicSupervisor.which_children/1`.

  This function delegates to all supervisors in the cluster and returns the aggregated output. Where memory warnings apply to `DynamicSupervisor.which_children`, these count double for `Horde.DynamicSupervisor.which_children`.
  """
  def which_children(supervisor), do: call(supervisor, :which_children)

  @doc """
  Works like `DynamicSupervisor.count_children/1`.

  This function delegates to all supervisors in the cluster and returns the aggregated output.
  """
  def count_children(supervisor), do: call(supervisor, :count_children)

  @doc """
  Waits for Horde.DynamicSupervisor to have quorum.
  """
  @spec wait_for_quorum(horde :: GenServer.server(), timeout :: timeout()) :: :ok
  def wait_for_quorum(horde, timeout) do
    GenServer.call(horde, :wait_for_quorum, timeout)
  end

  defp call(supervisor, msg), do: GenServer.call(supervisor, msg, :infinity)

  defp maybe_add_node_manager(children, :auto, name),
    do: [{Horde.NodeListener, name} | children]

  defp maybe_add_node_manager(children, _, _), do: children

  defp delta_crdt_options(options) do
    %{
      sync_interval: Keyword.get(options, :sync_interval, 300),
      max_sync_size: Keyword.get(options, :max_sync_size, :infinite),
      shutdown: Keyword.get(options, :shutdown, 30_000)
    }
  end

  defp members(:auto, _name), do: :auto

  defp members(options, name) do
    if name in options do
      options
    else
      [name | options]
    end
  end

  defp supervisor_name(name), do: :"#{name}.ProcessesSupervisor"
  defp crdt_name(name), do: :"#{name}.Crdt"
end
