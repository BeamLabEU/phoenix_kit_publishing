defmodule PhoenixKitPublishing.MigrationsRenamedHostTest do
  use PhoenixKitPublishing.DataCase, async: false

  alias Ecto.Migration.Runner
  alias PhoenixKit.Migrations.Postgres.Helpers
  alias PhoenixKitPublishing.Migrations
  alias PhoenixKitPublishing.Test.Repo

  @moduledoc """
  Reproduces the renamed-host shape the adversarial verification pass
  already dry-ran once (as a throwaway `/tmp` script, no longer on disk):
  every PK/FK/UNIQUE-constraint/index on all 7
  `phoenix_kit_publishing_*` tables renamed to an arbitrary different name,
  the way a real host-level rename migration leaves objects behind — see
  `PhoenixKitPublishing.Migrations`' moduledoc, "Guards are semantic, not
  name-based", for the sibling incident this defends against
  (`phoenix_kit_posts` ended up with 3 duplicate UNIQUE indexes from a
  name-based guard after a host-level rename, and a first cut of
  `PhoenixKitNewsletters.Migrations` crashed outright on a renamed host with
  `42P16 multiple primary keys`).

  The fixture is built from this chain's OWN `up_statements(@prefix, 1)`
  output (gets the correct, canonical shape for free), then every
  constraint and index is renamed to something else, and the marker is
  cleared — so the starting point is "the right shape, wrong names,
  never stamped by this chain".

  One wrinkle verified empirically against this environment's Postgres
  before writing the rename step: `ALTER TABLE ... RENAME CONSTRAINT`
  RENAMES A PK/UNIQUE CONSTRAINT'S OWN BACKING INDEX TOO (confirmed live —
  a constraint backed by an index is not a separate rename target). Only
  the 12 FKs (which have no backing index) and the 22 free-standing
  `idx_publishing_*` indexes need a SEPARATE `ALTER INDEX ... RENAME TO`
  pass, queried fresh AFTER the constraint renames so it never touches an
  index that renaming its constraint already renamed.

  Everything here runs against an isolated `pkpubrenamed_host` prefix schema
  inside the sandboxed test transaction (Postgres DDL is transactional, so
  it rolls back with everything else at `on_exit` — no manual cleanup), with
  a minimal one-column stub table standing in for `phoenix_kit_users` so the
  real FKs have something to reference.

  `async: false` — shares the migrator's sandbox connection, like
  `migrations_data_safety_test.exs`.
  """

  @prefix "pkpubrenamed_host"

  @tables ~w(
    phoenix_kit_publishing_groups
    phoenix_kit_publishing_posts
    phoenix_kit_publishing_versions
    phoenix_kit_publishing_contents
    phoenix_kit_publishing_categories
    phoenix_kit_publishing_post_categories
    phoenix_kit_publishing_post_views
  )

  defmodule RunUpToOneRenamedHost do
    @moduledoc false
    use Ecto.Migration

    def up, do: PhoenixKitPublishing.Migrations.up(prefix: "pkpubrenamed_host", version: 1)
    def down, do: :ok
  end

  setup do
    Repo.query!("CREATE SCHEMA IF NOT EXISTS #{@prefix}")
    Repo.query!("CREATE TABLE #{@prefix}.phoenix_kit_users (uuid uuid PRIMARY KEY)")

    # `uuid_generate_v7()` must exist in @prefix BEFORE the fixture's own
    # CREATE TABLE statements run — every "uuid" column's DEFAULT clause
    # references it by name, and Postgres validates a DEFAULT expression
    # against real catalog objects at CREATE TABLE time. pgcrypto itself is
    # already ensured by the main test suite's own migration bootstrap
    # (database-wide, not schema-scoped), so only the schema-qualified
    # function needs creating here.
    Helpers.ensure_extension!(Repo, "pgcrypto")
    Helpers.ensure_uuid_v7_function(Repo, @prefix)

    # The exact current (post-adoption) shape, under this chain's own
    # canonical names — built from the builder itself, not hand-typed, so
    # this fixture can never silently drift from what up_statements/2
    # actually emits.
    Migrations.up_statements(@prefix, 1)
    |> Enum.each(&Repo.query!(&1))

    rename_every_constraint()
    rename_every_remaining_index()

    # The marker above was stamped only because up_statements/2's own last
    # statement is the marker COMMENT — clear it, since this fixture
    # represents a host that has never run THIS chain (an independent
    # history that happens to already have the right shape post-rename),
    # not one that ran it once already.
    Repo.query!("COMMENT ON TABLE #{@prefix}.phoenix_kit_publishing_groups IS NULL")

    :ok
  end

  test "up/1 against a host whose PK/FK/UNIQUE-constraint/index objects carry arbitrary " <>
         "names does not error, does not duplicate any object, and still stamps the marker" do
    # This is the regression itself: a name-based PK guard raises
    # "multiple primary keys for table ... are not allowed" here.
    run_migration(RunUpToOneRenamedHost)

    # Every table still has exactly ONE primary key, under its renamed name
    # — no second, canonically-named PK was added alongside it.
    for {table, expected_columns} <- pkey_tables() do
      pkeys = pkey_rows(table)
      assert length(pkeys) == 1, "#{table}: expected exactly 1 primary key, got #{inspect(pkeys)}"
      {name, columns} = hd(pkeys)

      assert String.starts_with?(name, "z_"),
             "#{table}: pkey #{name} was not left under its renamed name"

      assert columns == expected_columns
    end

    # The 1 UNIQUE constraint (not a PK) is untouched under its renamed name
    # — no duplicate, canonically-named UNIQUE constraint was added.
    unique_constraints = constraint_rows("phoenix_kit_publishing_categories", "u")
    assert length(unique_constraints) == 1
    {uniq_name, uniq_columns} = hd(unique_constraints)
    assert String.starts_with?(uniq_name, "z_")
    assert uniq_columns == ["group_uuid", "slug"]

    # All 12 FKs are untouched under their renamed names — no duplicate,
    # differently-named FK was added alongside any of them.
    for {table, expected_count} <- fk_counts() do
      fks = fk_rows(table)

      assert length(fks) == expected_count,
             "#{table}: expected #{expected_count} FKs, got #{inspect(fks)}"

      assert Enum.all?(fks, fn {name, _target} -> String.starts_with?(name, "z_") end)
    end

    # All 22 free-standing indexes are untouched under their renamed names —
    # no duplicate, canonically-named index was added.
    for table <- @tables do
      free_standing = free_standing_index_names(table)

      assert Enum.all?(free_standing, &String.starts_with?(&1, "z_")),
             "#{table}: at least one free-standing index is not under its renamed name: #{inspect(free_standing)}"
    end

    assert total_index_count() == 30,
           "expected exactly 30 indexes across all 7 tables (22 free-standing + 7 pkey-backing " <>
             "+ 1 unique-constraint-backing) — a different count means something was duplicated " <>
             "or never created"

    assert Migrations.migrated_version_runtime(prefix: @prefix) == 1
  end

  test "a second up/1 run against the same renamed-host shape is idempotent" do
    run_migration(RunUpToOneRenamedHost)

    # up/1 short-circuits on `migrated_version(opts) < opts.version` — without
    # clearing the marker here, this second call would be a version-gate
    # no-op that never re-reaches the guarded statements, and "idempotent"
    # would be true for the wrong reason. Clearing it forces every guard to
    # run again against the now-canonically-shaped (post-1st-run) table, the
    # real idempotence claim this test makes.
    Repo.query!("COMMENT ON TABLE #{@prefix}.phoenix_kit_publishing_groups IS NULL")
    run_migration(RunUpToOneRenamedHost)

    # Still exactly one PK per table, 20 constraints, 30 indexes, still
    # version 1 — a second run must not add a THIRD copy of anything.
    for {table, _} <- pkey_tables() do
      assert length(pkey_rows(table)) == 1
    end

    assert length(constraint_rows("phoenix_kit_publishing_categories", "u")) == 1
    assert total_fk_count() == 12
    assert total_index_count() == 30

    assert Migrations.migrated_version_runtime(prefix: @prefix) == 1
  end

  # ── fixture setup helpers ───────────────────────────────────────────────

  defp rename_every_constraint do
    for table <- @tables, {old_name} <- constraint_names(table) do
      new_name = "z_" <> old_name
      Repo.query!("ALTER TABLE #{@prefix}.#{table} RENAME CONSTRAINT #{old_name} TO #{new_name}")
    end
  end

  # Queried AFTER the constraint renames, on purpose — renaming a PK/UNIQUE
  # constraint already renamed its own backing index (verified live, see
  # moduledoc), so an index whose name already starts with "z_" here is one
  # of those 8 and must be left alone; renaming it again would just be
  # renaming an already-renamed object, which is harmless but pointless —
  # skipped instead, so this loop only ever touches the 22 free-standing
  # `idx_publishing_*` indexes.
  defp rename_every_remaining_index do
    for table <- @tables,
        {old_name} <- all_index_names(table),
        not String.starts_with?(old_name, "z_") do
      new_name = "z_" <> old_name
      Repo.query!("ALTER INDEX #{@prefix}.#{old_name} RENAME TO #{new_name}")
    end
  end

  defp constraint_names(table) do
    %{rows: rows} =
      Repo.query!(
        "SELECT conname FROM pg_constraint WHERE conrelid = '#{@prefix}.#{table}'::regclass AND contype IN ('p', 'u', 'f')"
      )

    Enum.map(rows, &List.to_tuple/1)
  end

  defp all_index_names(table) do
    %{rows: rows} =
      Repo.query!(
        "SELECT indexname FROM pg_indexes WHERE schemaname = $1 AND tablename = $2",
        [@prefix, table]
      )

    Enum.map(rows, &List.to_tuple/1)
  end

  # ── assertion helpers ────────────────────────────────────────────────────

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

  defp pkey_tables do
    %{
      "phoenix_kit_publishing_groups" => ["uuid"],
      "phoenix_kit_publishing_posts" => ["uuid"],
      "phoenix_kit_publishing_versions" => ["uuid"],
      "phoenix_kit_publishing_contents" => ["uuid"],
      "phoenix_kit_publishing_categories" => ["uuid"],
      "phoenix_kit_publishing_post_categories" => ["post_uuid", "category_uuid"],
      "phoenix_kit_publishing_post_views" => ["post_uuid", "view_date"]
    }
  end

  defp fk_counts do
    %{
      "phoenix_kit_publishing_groups" => 0,
      "phoenix_kit_publishing_posts" => 4,
      "phoenix_kit_publishing_versions" => 2,
      "phoenix_kit_publishing_contents" => 1,
      "phoenix_kit_publishing_categories" => 2,
      "phoenix_kit_publishing_post_categories" => 2,
      "phoenix_kit_publishing_post_views" => 1
    }
  end

  defp pkey_rows(table), do: constraint_rows(table, "p")

  defp constraint_rows(table, contype) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT c.conname,
               (SELECT array_agg(a.attname ORDER BY k.ord)
                FROM unnest(c.conkey) WITH ORDINALITY AS k(attnum, ord)
                JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum)
        FROM pg_constraint c
        WHERE c.conrelid = '#{@prefix}.#{table}'::regclass AND c.contype = $1
        """,
        [contype]
      )

    Enum.map(rows, fn [name, columns] -> {name, columns} end)
  end

  defp fk_rows(table) do
    %{rows: rows} =
      Repo.query!("""
      SELECT c.conname, confrelid::regclass::text
      FROM pg_constraint c
      WHERE c.conrelid = '#{@prefix}.#{table}'::regclass AND c.contype = 'f'
      """)

    Enum.map(rows, fn [name, target] -> {name, target} end)
  end

  defp total_fk_count do
    Enum.reduce(@tables, 0, fn table, acc -> acc + length(fk_rows(table)) end)
  end

  defp free_standing_index_names(table) do
    pkey_or_unique_backed =
      constraint_rows(table, "p") |> Enum.map(&elem(&1, 0)) |> MapSet.new()

    unique_backed =
      if table == "phoenix_kit_publishing_categories" do
        constraint_rows(table, "u") |> Enum.map(&elem(&1, 0)) |> MapSet.new()
      else
        MapSet.new()
      end

    backed = MapSet.union(pkey_or_unique_backed, unique_backed)

    table
    |> all_index_names()
    |> Enum.map(&elem(&1, 0))
    |> Enum.reject(&MapSet.member?(backed, &1))
  end

  defp total_index_count do
    Enum.reduce(@tables, 0, fn table, acc -> acc + length(all_index_names(table)) end)
  end
end
