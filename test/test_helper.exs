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

      # Create minimal phoenix_kit_activities table — schema mirrors core's
      # V90 migration so PhoenixKit.Activity.log/1 INSERTs land cleanly
      # instead of crashing the sandbox transaction with `relation does
      # not exist`. ActivityLogAssertions queries this table directly.
      TestRepo.query!("""
      CREATE TABLE IF NOT EXISTS phoenix_kit_activities (
        uuid UUID PRIMARY KEY DEFAULT uuid_generate_v7(),
        action VARCHAR(100) NOT NULL,
        module VARCHAR(50),
        mode VARCHAR(20),
        actor_uuid UUID,
        resource_type VARCHAR(50),
        resource_uuid UUID,
        target_uuid UUID,
        metadata JSONB DEFAULT '{}',
        inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
      )
      """)

      # Create minimal phoenix_kit_buckets table — Storage.list_enabled_buckets/0
      # is called on mount of every LV that renders MediaSelectorModal
      # (Web.Editor's featured-image picker). An empty table is fine — the
      # query just needs to succeed; load_files only runs when the modal
      # is opened (show: true), which our smoke tests don't trigger.
      TestRepo.query!("""
      CREATE TABLE IF NOT EXISTS phoenix_kit_buckets (
        uuid UUID PRIMARY KEY DEFAULT uuid_generate_v7(),
        name VARCHAR(255) NOT NULL,
        provider VARCHAR(50) NOT NULL,
        region VARCHAR(100),
        endpoint VARCHAR(500),
        bucket_name VARCHAR(255),
        access_key_id VARCHAR(255),
        secret_access_key TEXT,
        cdn_url VARCHAR(500),
        access_type VARCHAR(20) NOT NULL DEFAULT 'public',
        enabled BOOLEAN NOT NULL DEFAULT TRUE,
        priority INTEGER NOT NULL DEFAULT 0,
        max_size_mb INTEGER,
        inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
      )
      """)

      # phoenix_kit_files / phoenix_kit_file_instances / phoenix_kit_media_folder_links
      # — touched when MediaSelectorModal load_files runs (Editor's
      # open_media_selector event). Empty tables are fine; LV pagination just
      # shows zero results.
      TestRepo.query!("""
      CREATE TABLE IF NOT EXISTS phoenix_kit_files (
        uuid UUID PRIMARY KEY DEFAULT uuid_generate_v7(),
        original_file_name VARCHAR(500),
        file_name VARCHAR(500),
        file_path VARCHAR(1000),
        mime_type VARCHAR(255),
        file_type VARCHAR(50),
        ext VARCHAR(20),
        file_checksum VARCHAR(255),
        user_file_checksum VARCHAR(255),
        size BIGINT,
        width INTEGER,
        height INTEGER,
        duration INTEGER,
        status VARCHAR(20) NOT NULL DEFAULT 'processing',
        trashed_at TIMESTAMPTZ,
        metadata JSONB DEFAULT '{}',
        user_uuid UUID,
        folder_uuid UUID,
        inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
      )
      """)

      TestRepo.query!("""
      CREATE TABLE IF NOT EXISTS phoenix_kit_file_instances (
        uuid UUID PRIMARY KEY DEFAULT uuid_generate_v7(),
        file_uuid UUID NOT NULL,
        bucket_uuid UUID,
        variant VARCHAR(50),
        file_path VARCHAR(1000),
        size BIGINT,
        width INTEGER,
        height INTEGER,
        url VARCHAR(2000),
        status VARCHAR(20) DEFAULT 'ready',
        inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
      )
      """)

      TestRepo.query!("""
      CREATE TABLE IF NOT EXISTS phoenix_kit_media_folder_links (
        uuid UUID PRIMARY KEY DEFAULT uuid_generate_v7(),
        file_uuid UUID NOT NULL,
        folder_uuid UUID NOT NULL,
        inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
      )
      """)

      # Create minimal oban_jobs table — Editor mount calls
      # `TranslatePostWorker.active_job/1` which queries Oban.Job to see
      # if a translation is in flight. The full Oban schema is too much
      # to mirror; we only need the columns the .active_job query reads
      # (state, worker, args, attempted_at). An empty table returns nil,
      # which is the expected "no in-flight translation" state.
      TestRepo.query!("""
      CREATE TABLE IF NOT EXISTS oban_jobs (
        id BIGSERIAL PRIMARY KEY,
        state VARCHAR(20) NOT NULL DEFAULT 'available',
        queue VARCHAR(100),
        worker VARCHAR(255),
        args JSONB DEFAULT '{}',
        meta JSONB DEFAULT '{}',
        tags VARCHAR(255)[] DEFAULT '{}',
        errors JSONB[] DEFAULT '{}',
        attempt INTEGER DEFAULT 0,
        attempted_by VARCHAR(255)[] DEFAULT '{}',
        max_attempts INTEGER DEFAULT 20,
        priority INTEGER DEFAULT 0,
        attempted_at TIMESTAMPTZ,
        cancelled_at TIMESTAMPTZ,
        completed_at TIMESTAMPTZ,
        discarded_at TIMESTAMPTZ,
        inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        scheduled_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
      )
      """)

      # Run the publishing migration to set up tables.
      # The migration module has up/1 (takes opts), so wrap it for Ecto.Migrator.
      defmodule PhoenixKitPublishing.Test.SetupMigration do
        use Ecto.Migration

        alias PhoenixKit.Modules.Publishing.Migrations.PublishingTables

        def up do
          PublishingTables.up(%{prefix: nil})
        end

        def down do
          PublishingTables.down(%{prefix: nil})
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

# PhoenixKit.Cache.Registry — Renderer.render_post calls PhoenixKit.Cache.get
# which needs the registry. Without this the cache hit/miss paths bail out
# via rescue clauses without exercising the actual cache logic.
{:ok, _pid} = PhoenixKit.Cache.Registry.start_link()

# Web.Listing's `handle_params/3` spawns a stale-fixer task via
# Task.Supervisor.start_child(PhoenixKit.TaskSupervisor, …) — start that
# supervisor under a tiny task supervisor so LV mount tests don't crash
# with `:noproc`. Same need for any LV that schedules background work.
{:ok, _pid} =
  Task.Supervisor.start_link(name: PhoenixKit.TaskSupervisor)

# Phoenix.Presence-via-`use` (PhoenixKit.Modules.Publishing.Presence)
# needs an actual Presence GenServer running, otherwise PresenceHelpers
# functions raise on `Presence.list/1`. The Editor LV's collaborative
# subsystem subscribes to this via PresenceHelpers.subscribe_to_editing/1.
# Phoenix.Presence-via-`use` exposes child_spec/1; start under a tiny
# supervisor so the Presence registry is up before any test runs.
# Reference: phoenix_kit_entities AGENTS.md notes the same trap for
# their EntityForm/DataForm LVs.
{:ok, _pid} =
  Supervisor.start_link(
    [PhoenixKit.Modules.Publishing.Presence],
    strategy: :one_for_one,
    name: PhoenixKitPublishing.Test.PresenceSupervisor
  )

# Pin PhoenixKit's URL prefix to "/" so public URLs built by the module
# (e.g. `Publishing.Web.HTML.group_listing_path/3`) don't prepend an
# unexpected prefix the test router wouldn't match.
:persistent_term.put({PhoenixKit.Config, :url_prefix}, "/")

# Start the test Endpoint only when the DB is available — controller
# tests both need a sandbox connection and the endpoint to drive
# requests. Support modules under `test/support/` are already compiled
# via `elixirc_paths(:test)` so we don't need to load them explicitly.
if repo_available do
  {:ok, _} = PhoenixKitPublishing.Test.Endpoint.start_link()
end

# Exclude integration tests when DB is not available
exclude = if repo_available, do: [], else: [:integration]

ExUnit.start(exclude: exclude)
