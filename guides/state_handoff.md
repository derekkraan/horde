# State Handoff

During deployment, when a server is restarted, its processes are restarted on other nodes. It can be useful to hand off state from the process that is shutting down to the process that is starting up.

Horde does not offer a specialized state handoff feature, instead we will be using OTP to accomplish state handoff.

## Trapping exits

When `Horde.Supervisor` is shutting down, it will send an exit signal to its child processes. We need to trap this signal to ensure that our `terminate/2` callback gets called.

```elixir
def init(arg) do
  Process.flag(:trap_exit, true)
  {:ok, arg}
end
```

## Saving state

We can then save the state in the terminate function.

```elixir
def terminate(reason, state) do
  save_state(state) # save state to Redis, DeltaCRDT, Postgres, Mysql, etc.
end
```

## Shutdown timeout

The default shutdown timeout is 0, which of course does not leave enough time to save our state. Increase the value of `shutdown` to make sure that your process has enough time to save its data. Be aware: `shutdown` must be set at all levels of your application to apply. A more restrictive shutdown timeout at a higher level in the supervision tree will override less restrictive values.

```elixir
children = [{Horde.Supervisor, [name: :my_supervisor, shutdown: 1000, strategy: :one_for_one]}]
```

## Restoring state

Now we have to modify the `init/1` callback to restore the state when the process is initializing. We put this in a `handle_continue/2` callback to avoid making the supervisor wait unnecessarily for the state to load.

```elixir
def init(arg) do
  Process.flag(:trap_exit, true)
  {:ok, arg, {:continue, :load_state}}
end

def handle_continue(:load_state, arg) do
  {:noreply, load_state(arg)}
end
```

### *_!!WARNING!!_*

We must be careful not to accidentally load invalid state into our processes. For example, if the state of a process changes between deploys, then you might load invalid state and cause your process to crash. Here are some other things to look out for:
- loading stale data
- loading data fails, causing process to crash
- there is no data to load, causing process to crash

Anytime we are loading state into our processes from an external source, we should be very careful. Erlang's "let it crash" philosophy is predicated on the idea that a process will be in a known good state after a restart, and if we subvert this by loading invalid state, it could have a negative impact on the stability of our system.
