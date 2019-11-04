{_, 0} = System.cmd("epmd", ["-daemon"])
:ok = LocalCluster.start()

Application.ensure_all_started(:horde)

ExUnit.start()
