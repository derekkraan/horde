defmodule Horde.MixProject do
  use Mix.Project

  def project do
    [
      app: :horde,
      version: "0.8.7",
      elixir: "~> 1.7",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      docs: docs(),
      package: package(),
      name: "Horde",
      source_url: "https://github.com/derekkraan/horde",
      aliases: [
        test: "test --no-start"
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:delta_crdt, "~> 0.6.2"},
      {:libring, "~> 1.4"},
      {:telemetry, "~> 1.0 or ~> 0.4.0"},
      {:telemetry_poller, "~> 1.0 or ~> 0.5.0"},
      {:ex_doc, "~> 0.16", only: :dev, runtime: false},
      {:benchee, "> 0.0.1", only: :dev, runtime: false},
      {:stream_data, "~> 0.4", only: :test},
      {:local_cluster, "~> 1.1", only: :test},
      {:schism, "~> 1.0.1", only: :test},
      {:dialyxir, "~> 1.0.0-rc.6", only: [:dev, :test], runtime: false},
      {:test_app, path: "test_app", only: [:test]}
    ]
  end

  defp package do
    [
      description: "Distributed supervisor & process registry built with δ-CRDTs",
      licenses: ["MIT"],
      maintainers: ["Derek Kraan"],
      links: %{GitHub: "https://github.com/derekkraan/horde"}
    ]
  end

  defp docs do
    [main: "readme", extras: extras()]
  end

  defp extras do
    # getting started
    [
      "README.md",
      "CHANGELOG.md",
      "guides/getting_started.md",
      "guides/eventual_consistency.md",
      "guides/state_handoff.md",
      "guides/libcluster.md"
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end
