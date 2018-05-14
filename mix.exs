defmodule Horde.MixProject do
  use Mix.Project

  def project do
    [
      app: :horde,
      version: "0.1.0",
      elixir: "~> 1.6",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: package()
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
      {:delta_crdt, git: "https://github.com/derekkraan/delta_crdt_ex"}
    ]
  end

  def package do
    [
      description: "Distributed process registry taking advantage of δ-CRDTs",
      licenses: ["MIT"],
      maintainers: ["Derek Kraan"],
      links: %{github: "https://github.com/derekkraan/horde"}
    ]
  end
end
