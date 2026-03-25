import Config

# Test database configuration
# Integration tests need a real PostgreSQL database. Create it with:
#   createdb phoenix_kit_publishing_test
config :phoenix_kit_publishing, ecto_repos: [PhoenixKitPublishing.Test.Repo]

config :phoenix_kit_publishing, PhoenixKitPublishing.Test.Repo,
  username: System.get_env("PGUSER", "postgres"),
  password: System.get_env("PGPASSWORD", "postgres"),
  hostname: System.get_env("PGHOST", "localhost"),
  database: "phoenix_kit_publishing_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# Wire repo for PhoenixKit.RepoHelper — without this, all DB calls crash.
config :phoenix_kit, repo: PhoenixKitPublishing.Test.Repo

config :logger, level: :warning
