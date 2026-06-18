defmodule Must.MixProject do
  use Mix.Project

  def project do
    [
      app: :must,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      name: "Must",
      source_url: "https://github.com/type1fool/must",
      deps: deps(),
      docs: docs()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Must.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ex_doc, "~> 0.40.3", only: :dev, runtime: false, warn_if_outdated: true},
      {:telemetry, "~> 1.4"}
    ]
  end

  defp docs do
    [
      main: "Must",
      extras: ["README.md"]
    ]
  end
end
