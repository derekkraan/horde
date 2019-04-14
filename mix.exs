defmodule Horde.MixProject do
  use Mix.Project

  def project do
    [
      app: :horde,
      version: "0.5.0-rc.11",
      elixir: "~> 1.7",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      package: package(),
      name: "Horde",
      source_url: "https://github.com/derekkraan/horde"
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
      {:delta_crdt, "~> 0.4.3",
       github: "derekkraan/delta_crdt_ex", branch: "merkle_anti_entropy"},
      {:xxhash, "~> 0.1"},
      {:ex_doc, "~> 0.16", only: :dev, runtime: false},
      {:benchee, "> 0.0.1", only: :dev, runtime: false},
      {:stream_data, "~> 0.4", only: :test},
      {:local_cluster, "~> 1.0.4", only: :test},
      {:schism, "~> 1.0.1", only: :test}
    ]
  end

  def package do
    [
      description: "Distributed supervisor & process registry built with δ-CRDTs",
      licenses: ["MIT"],
      maintainers: ["Derek Kraan"],
      links: %{GitHub: "https://github.com/derekkraan/horde"}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end
