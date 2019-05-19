# Horde Example - Distributed CountersAdd and example of routing messages to a growing set of managed processes

An example application that demonstrates using [Horde] (https://github.com/derekkraan/horde) to manage a collection of dynamically-created processes, each responsible for a specific set of messages and created automatically when a relevant message is received.

There is one GenServer (`Worker`) which acts as a simple counter (casting `:increment` increments the count asynchronously and calling `:value` returns the current count).  The `Router` module allows you to increment different counters denoted by an atom `name`.  Internally, `Router` uses `Horde.Registry.lookup` to determine if a `Worker` process for a given `name` exists and if not starts one.  Then it either calls that process using the PID returned or using the `:via` method as outlined in the Horde documentation.


To see it in action, start up three nodes locally with `iex`. From the root of this application, run each of the following in its own terminal:

```
> iex --name count1@127.0.0.1 -S mix
> iex --name count2@127.0.0.1 -S mix
> iex --name count3@127.0.0.1 -S mix
```

From one of the terminals openned, you can interact directly with the `Router` using:

```
> Counter.Router.Via.increment(:foo)
> Counter.Router.Via.increment(:foo)
> Counter.Router.Via.increment(:bar)
> Counter.Router.Via.value(:foo)
2
> Counter.Router.Via.value(:bar)
1
```

Or you can use the PID-based method:

```
> Counter.Router.PID.increment(:foo)
> Counter.Router.PID.value(:foo)
1
```

