defmodule PhoenixKitPublishing.MigrationsExpressionIndexTest do
  use PhoenixKitPublishing.DataCase, async: false

  alias Ecto.Migration.Runner
  alias PhoenixKit.Migrations.Postgres.Helpers
  alias PhoenixKitPublishing.Migrations
  alias PhoenixKitPublishing.Test.Repo

  @moduledoc """
  Regression test for a real bug class the semantic index guard
  (`PhoenixKitPublishing.Migrations`' `index_guard/7`) defends against: a
  pre-existing EXPRESSION index sharing one column name with a plain index
  this chain wants to adopt could be misread as "the plain index already
  exists", silently skipping its creation — see the moduledoc's
  `index_guard/7` comment ("`i.indexprs IS NULL` and the `array_length`
  check below both exist for the same real bug...").

  `pg_index.indkey` stores `0` — not a real attnum — for an expression
  column (e.g. the `lower(name)` half of `ON t (status, lower(name))`).
  `pg_attribute` has no row for attnum `0`, so a naive
  `JOIN pg_attribute ON attnum = k.attnum` silently DROPS that array
  position instead of erroring, shortening a 2-column expression index's
  resolved column list down to `{status}` — indistinguishable, by that
  aggregate alone, from the real, unrelated, single-column
  `idx_publishing_groups_status`.

  Adapted to this chain's own `idx_publishing_groups_status` (a plain btree
  index on `phoenix_kit_publishing_groups.status`, no partial predicate) —
  the simplest of this chain's 22 indexes, and enough to reproduce the bug:
  the guard's column-aggregate collapsing a 2-key expression index down to
  `{status}` doesn't depend on which table it happens on.

  `async: false` — shares the migrator's sandbox connection, like the other
  migration test files that run a real `up/1`.
  """

  @prefix "pkpubexpr_host"

  defmodule RunUpToOneExpressionIndexHost do
    @moduledoc false
    use Ecto.Migration

    def up, do: PhoenixKitPublishing.Migrations.up(prefix: "pkpubexpr_host", version: 1)
    def down, do: :ok
  end

  setup do
    Repo.query!("CREATE SCHEMA IF NOT EXISTS #{@prefix}")
    Repo.query!("CREATE TABLE #{@prefix}.phoenix_kit_users (uuid uuid PRIMARY KEY)")

    Helpers.ensure_extension!(Repo, "pgcrypto")
    Helpers.ensure_uuid_v7_function(Repo, @prefix)

    # The full current shape, correct (canonical) object names throughout,
    # EXCEPT `idx_publishing_groups_status` is deliberately dropped right
    # after the fixture is built — its absence is the point: the only index
    # touching `status` on `phoenix_kit_publishing_groups` is the unrelated
    # expression index added below, so this reproduces "the real plain
    # index is genuinely missing, but something else on the table happens
    # to share its first column".
    Migrations.up_statements(@prefix, 1)
    |> Enum.each(&Repo.query!(&1))

    Repo.query!("DROP INDEX #{@prefix}.idx_publishing_groups_status")
    Repo.query!("COMMENT ON TABLE #{@prefix}.phoenix_kit_publishing_groups IS NULL")

    # An unrelated third-party-tool-style EXPRESSION index that happens to
    # touch the same first column (`status`) as the real, now-missing,
    # plain index.
    Repo.query!("""
    CREATE INDEX some_other_tools_expression_index ON #{@prefix}.phoenix_kit_publishing_groups
      USING btree (status, lower(name))
    """)

    :ok
  end

  test "up/1 creates the real plain status index even when an unrelated expression " <>
         "index on the same table shares the first column name" do
    run_migration(RunUpToOneExpressionIndexHost)

    # The regression: BEFORE the fix, the guard's column-aggregate silently
    # dropped the expression index's second (expression) key down to just
    # `{status}`, matched it against the expected `ARRAY['status']`, and
    # concluded the real plain index already existed — skipping its
    # creation entirely. Assert it actually got created.
    assert index_exists?("idx_publishing_groups_status")

    # The pre-existing expression index is untouched — this chain never
    # drops anything, adoption or not.
    assert index_exists?("some_other_tools_expression_index")

    # Both indexes coexist distinctly — 2 indexes touching `status`, not 1
    # (which would mean the real one never got created) and not 3 (which
    # would mean something got duplicated).
    assert status_touching_index_count() == 2

    assert Migrations.migrated_version_runtime(prefix: @prefix) == 1
  end

  test "a second up/1 run stays idempotent with the expression index still present" do
    run_migration(RunUpToOneExpressionIndexHost)

    # Without clearing the marker, up/1's version gate makes the second call
    # below a no-op that never re-reaches the guarded statements — clear it
    # so this test genuinely re-exercises the index guard against the
    # now-fully-created shape, not just the version check.
    Repo.query!("COMMENT ON TABLE #{@prefix}.phoenix_kit_publishing_groups IS NULL")
    run_migration(RunUpToOneExpressionIndexHost)

    assert status_touching_index_count() == 2
    assert Migrations.migrated_version_runtime(prefix: @prefix) == 1
  end

  # ── helpers ──────────────────────────────────────────────────────────

  defp run_migration(module) do
    Runner.run(
      Repo,
      [],
      :os.system_time(:microsecond),
      module,
      :forward,
      :up,
      :up,
      log: false,
      log_migrations_sql: false
    )
  end

  defp index_exists?(name) do
    %{rows: rows} =
      Repo.query!(
        "SELECT 1 FROM pg_indexes WHERE schemaname = $1 AND tablename = $2 AND indexname = $3",
        [@prefix, "phoenix_kit_publishing_groups", name]
      )

    rows != []
  end

  defp status_touching_index_count do
    %{rows: [[count]]} =
      Repo.query!(
        """
        SELECT count(*) FROM pg_indexes
        WHERE schemaname = $1 AND tablename = $2 AND indexdef ILIKE '%(status%'
        """,
        [@prefix, "phoenix_kit_publishing_groups"]
      )

    count
  end
end
