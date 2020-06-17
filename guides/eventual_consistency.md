# Eventual Consistency

Horde uses a CRDT to sync data between nodes. This means that two nodes in your cluster can have a different view of the data, with differences being merged as the nodes sync with each other. We call this "eventually consistent", and the result is that we have to deal with merge conflicts and race conditions. Horde's CRDT automatically resolves conflicts, but we still have to deal with the after-effects.

## Horde.DynamicSupervisor merge conflict

It is unlikely, but possible, that Horde.DynamicSupervisor will start the same process on two separate nodes.

This can happen:
- if using a custom distribution strategy, or
- when a node dies and not all nodes have the same view of the cluster, or
- if there is a network partition.

Once a network partition has healed, Horde will automatically terminate any duplicate processes.

## Horde.Registry merge conflict

When processes on two different nodes have claimed the same name, this will generate a conflict in Horde.Registry. The CRDT resolves the conflict and Horde.Registry sends an exit signal to the process that lost the conflict. This can be a common occurrence.

Unless this message is handled, it will cause the process to exit. Handling the exit message isn't strictly necessary, because we usually want the process to exit in this case. If for some reason you want to handle the message, simply trap exits in the `init/1` callback and handle the message as follows:

```elixir
def init(arg) do
  Process.flag(:trap_exit, true)
  {:ok, state}
end

def handle_info({:EXIT, _from, {:name_conflict, {key, value}, registry, pid}}, state) do
  # handle the message, add some logging perhaps, and probably stop the GenServer.
  {:stop, :normal, state}
end
```

Note that, unless your process has `restart: :transient` in its child spec and you have handled the message to shut down the process cleanly, it will be restarted by its supervisor.

Upon restart, it will try to register itself. This will of course fail. If using a via tuple, the following approach is necessary.

```elixir
def start_link(arg) do
  case GenServer.start_link(...) do
    {:ok, pid} ->
      {:ok, pid}
    {:error, {:already_started, pid}} ->
      :ignore
  end
end
```

If you are using `Horde.Registry.register/3` in `init/1`, then you must handle `{:error, {:already_started, pid}}`.

```elixir
def init(arg) do
  case Horde.Registry.register(:my_registry, "key", "value") do
    {:ok, _pid} ->
      {:ok, arg}
    {:error, {:already_registered, _pid}} ->
      :ignore
  end
end
```
