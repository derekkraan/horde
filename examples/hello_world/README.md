# Distributed Supervisor / Registry "hello world"

This is an example application that shows how `Horde.Supervisor` and `Horde.Registry` work together.

Start the app in two separate terminal windows with:

`ERL_AFLAGS="-name count1@127.0.0.1 -setcookie asdf" HELLO_NODES="count2@127.0.0.1" iex -S mix`

and 

`ERL_AFLAGS="-name count2@127.0.0.1 -setcookie asdf" HELLO_NODES="count1@127.0.0.1" iex -S mix`

You should notice the message `HELLO from node X` printing in just one of the two instances. If you close that instance, you should (almost instantly) see the messages being output by the other instance.

Other than that, this is a very minimal example of what one would need to do to get up and running with `Horde`. 
