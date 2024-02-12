:ok = LocalCluster.start()
Application.ensure_all_started(:dynamic)

ExUnit.start()
