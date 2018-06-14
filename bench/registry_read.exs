{:ok, _h1} = Horde.Registry.start_link(name: Horde1)

1..100_000
|> Enum.each(fn x ->
  Horde.Registry.register(Horde1, x, spawn(fn -> Process.sleep(5000) end))
end)

Benchee.run(
  %{
    "Horde.Registry.lookup/2" => fn ->
      Horde.Registry.lookup(Horde1, 100)
    end
  },
  parallel: 4
)
