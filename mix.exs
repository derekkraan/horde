defmodule Horde.MixProject do
  use Mix.Project

  def project do
    [
      app: :horde,
      version: "0.4.0-rc.2",
      elixir: "~> 1.7",
      start_permanent: Mix.env() == :prod,
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
      {:delta_crdt, "~> 0.4"},
      {:xxhash, "~> 0.1"},
      {:ex_doc, "~> 0.16", only: :dev, runtime: false},
      {:stream_data, "~> 0.4", only: :test},
      {:benchee, "> 0.0.1", only: :dev, runtime: false}
    ]
  end

  def package do
    [
      description: "Distributed supervisor & process registry built with δ-CRDTs",
      licenses: ["MIT"],
      maintainers: ["Derek Kraan"],
      links: %{github: "https://github.com/derekkraan/horde"}
    ]
  end
end
