defmodule Must.MixProject do
  use Mix.Project

  def project do
    [
      app: :must,
      version: "0.1.1-dev",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      name: "Must",
      source_url: "https://github.com/type1fool/must",
      deps: deps(),
      docs: docs(),
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
      {:ecto, "~> 3.14"},
      {:ecto_sql, "~> 3.14"},
      {:ecto_sqlite3, "~> 0.24"},
      {:jason, "~> 1.4"},
      {:ex_doc, "~> 0.40.3", only: :dev, runtime: false, warn_if_outdated: true},
      {:telemetry, "~> 1.4"}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp docs do
    [
      main: "Must",
      extras: ["README.md"]
    ]
  end

  defp package do
    [
      name: :must,
      description: "A simplified change processing library",
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/type1fool/must"},
      files: ~w(mix.exs README.md lib/must.ex lib/must)
    ]
  end
end
