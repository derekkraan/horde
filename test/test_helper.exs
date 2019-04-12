:ok = LocalCluster.start()

Application.ensure_all_started(:horde)

ExUnit.start()
