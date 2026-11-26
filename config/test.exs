import Config

# Test database configuration
# Integration tests need a real PostgreSQL database. Create it with:
#   createdb phoenix_kit_publishing_test
config :phoenix_kit_publishing, ecto_repos: [PhoenixKitPublishing.Test.Repo]

# `PGDATABASE` lets this suite point at a database the test role isn't
# allowed to CREATE (a shared instance). Left unset, this falls back to the
# previous hard-coded name, so CI is unaffected.
pg_test_db =
  case System.get_env("PGDATABASE") do
    value when is_binary(value) and value != "" -> String.trim(value)
    _ -> "phoenix_kit_publishing_test#{System.get_env("MIX_TEST_PARTITION")}"
  end

config :phoenix_kit_publishing, PhoenixKitPublishing.Test.Repo,
  username: System.get_env("PGUSER", "postgres"),
  password: System.get_env("PGPASSWORD", "postgres"),
  hostname: System.get_env("PGHOST", "localhost"),
  database: pg_test_db,
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# Wire repo for PhoenixKit.RepoHelper — without this, all DB calls crash.
config :phoenix_kit, repo: PhoenixKitPublishing.Test.Repo

# Point LayoutWrapper at our test layouts so controller tests render
# through `Test.Layouts.app/1` instead of `PhoenixKitWeb.Layouts.root`
# (which requires the PhoenixKitWeb.Endpoint persistent term).
config :phoenix_kit, layout: {PhoenixKitPublishing.Test.Layouts, :app}

# Test Endpoint for controller integration tests. `phoenix_kit_publishing`
# has no endpoint of its own in production — the host app provides one —
# so this tiny endpoint only exists for `Phoenix.ConnTest`.
config :phoenix_kit_publishing, PhoenixKitPublishing.Test.Endpoint,
  secret_key_base: String.duplicate("t", 64),
  server: false,
  url: [host: "localhost"],
  render_errors: [formats: [html: PhoenixKitPublishing.Test.Layouts]],
  live_view: [signing_salt: "publishing-test-live-view-salt-1234567890ab"]

# Endpoint for the real-macro dispatch harness (Test.DispatchRouter —
# phoenix_kit_routes() end-to-end; see dispatch_e2e_test.exs).
config :phoenix_kit_publishing, PhoenixKitPublishing.Test.DispatchEndpoint,
  secret_key_base: String.duplicate("d", 64),
  server: false,
  url: [host: "localhost"],
  render_errors: [formats: [html: PhoenixKitPublishing.Test.Layouts]],
  live_view: [signing_salt: "publishing-dispatch-live-view-salt-123456"]

config :phoenix, :json_library, Jason

config :logger, level: :warning
