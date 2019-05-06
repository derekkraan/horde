# Distributed Supervisor / Registry "hello world"

This is an example application that shows how `Horde.Supervisor` and `Horde.Registry` work together.

Start the app in separate terminal windows with:

`iex --name count1@127.0.0.1 --cookie asdf -S mix`

and

`iex --name count2@127.0.0.1 --cookie asdf -S mix`

and

`iex --name count3@127.0.0.1 --cookie asdf -S mix`

You should notice the message `HELLO from node X` printing in just one of the instances. If you close that instance, you should (almost instantly) see the messages being output by the other instance.

We use the `meta/2` and `put_meta/3` functions on `Horde.Registry` to share the value for the counter across the members of the Horde. This means that when the node running `HelloWorld.SayHello` is killed, the new instance started by the `Horde.Supervisor` will pick up the counter from the meta data shared across the `Horde.Registry` to continue the count where the previous instance left off. You can get the count by running `HelloWorld.SayHello.how_many?`

You can also call `HelloWorld.Application.how_many?` from any of the IEX consoles to retrieve the current value of the counter. 

Other than that, this is a very minimal example of what one would need to do to get up and running with `Horde`.
