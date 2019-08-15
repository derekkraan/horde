# Distributed Supervisor / Registry "hello world"

This is an example application that shows how `Horde.Supervisor` and `Horde.Registry` work together using dynamic cluster membership.

Start the app in separate terminal windows with:

`iex --name w1@127.0.0.1 --cookie asdf -S mix`

and

`iex --name w2@127.0.0.1 --cookie asdf -S mix`

and

`iex --name w3@127.0.0.1 --cookie asdf -S mix`


On any of the terminal windows, you can now create "entities" (which is anything you desire). Type in the following to any of the terminal windows:

```
iex> Dynamic.create_entity("UniqueName", %{some: :data, about: "it"})
```

Now on any other node, you can get the data again:

```
iex> Dynamic.get_entity("UniqueName")
%{some: :data, about: "it"}
```

This alone is not too suprising. Now kill the node which created the entity (CTRL-C twice). Notice the other machines can still fetch the data.

We use the `meta/2` and `put_meta/3` functions on `Horde.Registry` to share the data for the entity across the members of the Horde. This means that when the node running `Dynamic.Entity` is killed, the new instance started by the `Horde.Supervisor` will pick up the data from the meta data shared across the `Horde.Registry` to continue processing where the previous instance left off. You can get the data of an entity by running `Dynamic.get_entity(name_of_entity)`.

You can also call `Dynamic.Entity.all()` from any of the IEX consoles to retrieve all the entity workers.
