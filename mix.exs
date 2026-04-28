defmodule PhoenixKitPublishing.MixProject do
  use Mix.Project

  @version "0.1.5"
  @source_url "https://github.com/BeamLabEU/phoenix_kit_publishing"

  def project do
    [
      app: :phoenix_kit_publishing,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),

      # Hex
      description:
        "Publishing module for PhoenixKit — database-backed CMS with multi-language support",
      package: package(),

      # Dialyzer
      dialyzer: [plt_add_apps: [:phoenix_kit]],

      # Test coverage — filter test-support modules out of `mix test --cover`
      # so the percentage reflects production code only.
      test_coverage: [
        ignore_modules: [
          ~r/^PhoenixKitPublishing\.Test\./,
          PhoenixKitPublishing.ConnCase,
          PhoenixKitPublishing.LiveCase,
          PhoenixKitPublishing.DataCase,
          PhoenixKitPublishing.PhoenixKitDataCase,
          PhoenixKitPublishing.ActivityLogAssertions,
          PhoenixKitPublishing.TestRepo
        ]
      ],

      # Docs
      name: "PhoenixKitPublishing",
      source_url: @source_url,
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp aliases do
    [
      quality: ["format", "credo --strict", "dialyzer"],
      "quality.ci": ["format --check-formatted", "credo --strict", "dialyzer"],
      precommit: ["compile", "quality"]
    ]
  end

  defp deps do
    [
      # PhoenixKit provides the Module behaviour, Settings API, and core infrastructure.
      {:phoenix_kit, "~> 1.7"},
      {:phoenix_kit_ai, "~> 0.1"},

      # LiveView for admin pages
      {:phoenix_live_view, "~> 1.0"},

      # Markdown rendering
      {:earmark, "~> 1.4"},

      # XML parsing for PHK page builder components
      {:saxy, "~> 1.5"},

      # Background jobs (translation worker, migration worker)
      {:oban, "~> 2.18"},

      # Code quality (dev/test only)
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},

      # LiveView test parser (test only)
      {:lazy_html, "~> 0.1", only: :test}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib .formatter.exs mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "PhoenixKit.Modules.Publishing",
      source_ref: "v#{@version}",
      extras: ["phk-publishing-format.md"]
    ]
  end
end
