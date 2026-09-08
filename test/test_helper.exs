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

# The preflight ships in core, and this module's core floor (`~> 2.0`)
# predates it — so it is used when the running core has it, and otherwise
# this falls through to exactly the previous behaviour.
db_check =
  if Code.ensure_loaded?(PhoenixKit.TestSupport.PostgresPreflight) do
    # One classified connection attempt, with the repo's OWN credentials and
    # transport, before anything starts the pool.
    #
    # This replaces a `psql -lqt` listing. That check asked the wrong question:
    # it ran as the shell's user over a unix socket, so it reported "the
    # database is there" and said nothing about whether the CONFIGURED role
    # could reach it over TCP. When it could not, the answer arrived minutes
    # later as a pool checkout timeout that reads like a flaky test.
    case PhoenixKit.TestSupport.PostgresPreflight.check(db_config) do
      :ok ->
        :exists

      {:error, _reason, message} ->
        IO.puts(:stderr, "\n" <> message)
        :not_found
    end
  else
    :try_connect
  end

repo_available =
  if db_check == :not_found do
    IO.puts("""
    \n  Cannot reach test database "#{db_name}" — integration tests excluded.
       The reason is printed above.
    """)

    false
  else
    try do
      {:ok, _} = TestRepo.start_link()

      # Build the schema directly from core's versioned migrations — same
      # call the host app makes in production. Every publishing table
      # (groups/posts/versions/contents) lives in core's V59; the support
      # tables this suite touches (settings V03, activities V90, buckets
      # / files / file_instances V20+, media_folder_links V95, oban_jobs
      # via V27's `Oban.Migration.up/1`) are also owned by core. No
      # module-side DDL anywhere — schema drift between test and prod
      # is impossible by construction.
      #
      # `ensure_current/2` (core 1.7.105+ / phoenix_kit#515) re-applies
      # any newly-shipped Vxxx migrations on every boot by passing a
      # fresh wall-clock version to Ecto.Migrator. Replaces the
      # `Ecto.Migrator.run([{0, PhoenixKit.Migration}], :up, all: true)`
      # pattern, which silently stopped re-applying once `0` was
      # recorded in `schema_migrations` — see
      # `dev_docs/migration_cleanup.md` for the staleness story.
      PhoenixKit.Migration.ensure_current(TestRepo, log: false)

      Ecto.Adapters.SQL.Sandbox.mode(TestRepo, :manual)
      true
    rescue
      e ->
        IO.puts("""
        \n  Could not connect to test database — integration tests excluded.           The reason is printed above.
           Error: #{Exception.message(e)}
        """)

        false
    catch
      :exit, reason ->
        IO.puts("""
        \n  Could not connect to test database — integration tests excluded.           The reason is printed above.
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
  {:ok, _} = PhoenixKitPublishing.Test.DispatchEndpoint.start_link()
end

# Exclude integration tests when DB is not available
exclude = if repo_available, do: [], else: [:integration]

ExUnit.start(exclude: exclude)
