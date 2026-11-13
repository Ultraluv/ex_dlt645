defmodule ExDlt645.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/Ultraluv/ex_dlt645"

  def project do
    [
      app: :ex_dlt645,
      version: @version,
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      description: description(),
      package: package(),
      docs: docs(),
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {ExDlt645.Application, []}
    ]
  end

  defp deps do
    [
      {:circuits_uart, "~> 1.4"},
      {:telemetry, "~> 1.0"},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false}
    ]
  end

  defp description do
    "A pure Elixir implementation of DL/T 645-2007 (and 1997) electricity meter communication protocol with hardware-free simulation bus, Circuits.UART framing, and master/slave roles."
  end

  defp package do
    [
      name: "ex_dlt645",
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE CHANGELOG.md),
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url
      }
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: @source_url,
      source_ref: "v#{@version}",
      formatters: ["html"],
      extras: ["README.md", "CHANGELOG.md", "LICENSE"]
    ]
  end
end
