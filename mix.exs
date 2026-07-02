defmodule PhoenixKitPublishing.MixProject do
  use Mix.Project

  @version "0.2.2"
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
      precommit: [
        "compile --force --warnings-as-errors",
        "deps.unlock --check-unused",
        # Scan for retired Hex deps. Run via `cmd` so Hex bootstraps in a fresh
        # process — the hex.* archive tasks aren't resolvable via Mix.Task.run
        # inside an alias.
        "cmd mix hex.audit",
        "quality.ci"
      ]
    ]
  end

  # phoenix_kit deps resolve from Hex by default. For cross-repo work against a
  # local checkout, export <APP>_PATH — e.g. PHOENIX_KIT_PATH=../phoenix_kit or
  # PHOENIX_KIT_AI_PATH=../phoenix_kit_ai. Unset => the published pin, so
  # mix hex.publish is unaffected.
  defp pk_dep(app, requirement, opts \\ []) do
    env_var = String.upcase(Atom.to_string(app)) <> "_PATH"

    case System.get_env(env_var) do
      nil when opts == [] -> {app, requirement}
      nil -> {app, requirement, opts}
      path -> {app, [path: path, override: true] ++ opts}
    end
  end

  defp deps do
    [
      # PhoenixKit provides the Module behaviour, Settings API, and core infrastructure.
      pk_dep(:phoenix_kit, "~> 1.7.132"),
      # PhoenixKitAI owns the generic AI-translation pipeline that this module's
      # `AITranslatable` adapter plugs into.
      pk_dep(:phoenix_kit_ai, "~> 0.4"),

      # LiveView for admin pages
      {:phoenix_live_view, "~> 1.0"},

      # Markdown rendering (MDEx/comrak; also pulled in by phoenix_kit core)
      {:mdex, "~> 0.13"},

      # XML parsing for PHK page builder components
      {:saxy, "~> 1.5"},

      # Background jobs (translation worker, migration worker)
      {:oban, "~> 2.18"},

      # Optional rustler pin so the transitive `mdex_native` NIF can
      # source-build on hosts where its precompiled variant doesn't
      # match the local NIF version. Matches the parent app's pin.
      {:rustler, ">= 0.0.0", optional: true},

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
