# Test helper for PhoenixKitPublishing test suite
#
# Level 1: Unit tests (schemas, changesets, pure functions) always run.
# Level 2: Integration tests require PostgreSQL — automatically excluded
#          when the database is unavailable.
#
# To enable integration tests:
#   createdb phoenix_kit_publishing_test

alias PhoenixKitPublishing.Test.Repo, as: TestRepo

# Check if the test database exists before trying to connect
db_config = Application.get_env(:phoenix_kit_publishing, TestRepo, [])
db_name = db_config[:database] || "phoenix_kit_publishing_test"

db_check =
  case System.cmd("psql", ["-lqt"], stderr_to_stdout: true) do
    {output, 0} ->
      exists =
        output
        |> String.split("\n")
        |> Enum.any?(fn line ->
          line |> String.split("|") |> List.first("") |> String.trim() == db_name
        end)

      if exists, do: :exists, else: :not_found

    _ ->
      :try_connect
  end

repo_available =
  if db_check == :not_found do
    IO.puts("""
    \n  Test database "#{db_name}" not found — integration tests excluded.
       Run: createdb #{db_name}
    """)

    false
  else
    try do
      {:ok, _} = TestRepo.start_link()

      # Enable uuid-ossp extension
      TestRepo.query!("CREATE EXTENSION IF NOT EXISTS \"uuid-ossp\"")

      # Create uuid_generate_v7() function (normally created by PhoenixKit core migration)
      TestRepo.query!("""
      CREATE OR REPLACE FUNCTION uuid_generate_v7()
      RETURNS uuid AS $$
      DECLARE
        unix_ts_ms bytea;
        uuid_bytes bytea;
      BEGIN
        unix_ts_ms := substring(int8send(floor(extract(epoch FROM clock_timestamp()) * 1000)::bigint) FROM 3);
        uuid_bytes := unix_ts_ms || gen_random_bytes(10);
        uuid_bytes := set_byte(uuid_bytes, 6, (get_byte(uuid_bytes, 6) & 15) | 112);
        uuid_bytes := set_byte(uuid_bytes, 8, (get_byte(uuid_bytes, 8) & 63) | 128);
        RETURN encode(uuid_bytes, 'hex')::uuid;
      END;
      $$ LANGUAGE plpgsql VOLATILE;
      """)

      # Create minimal phoenix_kit_settings table (needed by LanguageHelpers)
      TestRepo.query!("""
      CREATE TABLE IF NOT EXISTS phoenix_kit_settings (
        uuid UUID PRIMARY KEY DEFAULT uuid_generate_v7(),
        key VARCHAR(255) NOT NULL UNIQUE,
        value VARCHAR(255),
        value_json JSONB,
        module VARCHAR(255),
        date_added TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        date_updated TIMESTAMPTZ NOT NULL DEFAULT NOW()
      )
      """)

      # Run the publishing migration to set up tables.
      # The migration module has up/1 (takes opts), so wrap it for Ecto.Migrator.
      defmodule PhoenixKitPublishing.Test.SetupMigration do
        use Ecto.Migration

        def up do
          PhoenixKit.Modules.Publishing.Migrations.PublishingTables.up(%{prefix: nil})
        end

        def down do
          PhoenixKit.Modules.Publishing.Migrations.PublishingTables.down(%{prefix: nil})
        end
      end

      Ecto.Migrator.up(TestRepo, 1, PhoenixKitPublishing.Test.SetupMigration, log: false)

      Ecto.Adapters.SQL.Sandbox.mode(TestRepo, :manual)
      true
    rescue
      e ->
        IO.puts("""
        \n  Could not connect to test database — integration tests excluded.
           Run: createdb #{db_name}
           Error: #{Exception.message(e)}
        """)

        false
    catch
      :exit, reason ->
        IO.puts("""
        \n  Could not connect to test database — integration tests excluded.
           Run: createdb #{db_name}
           Error: #{inspect(reason)}
        """)

        false
    end
  end

Application.put_env(:phoenix_kit_publishing, :test_repo_available, repo_available)

# Start minimal PhoenixKit services needed for tests
{:ok, _pid} = PhoenixKit.PubSub.Manager.start_link([])
{:ok, _pid} = PhoenixKit.ModuleRegistry.start_link([])

# Exclude integration tests when DB is not available
exclude = if repo_available, do: [], else: [:integration]

ExUnit.start(exclude: exclude)
