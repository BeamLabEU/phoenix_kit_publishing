defmodule PhoenixKitPublishing.MigrationsCatalogParityTest do
  use PhoenixKitPublishing.DataCase, async: false

  alias PhoenixKit.Migrations.Postgres.Helpers
  alias PhoenixKitPublishing.Migrations
  alias PhoenixKitPublishing.Test.Repo

  @moduledoc """
  Phase 2's claim, proven against a real catalog: V1's DDL, run into an
  EMPTY schema, builds exactly what core's own chain built in `public`.

  `migrations_test.exs` compares the statements against core's
  `ExpectedSchema` manifest — a comparison of text with text. This file
  compares what Postgres actually recorded: every column (type, width,
  nullability, default), every PK/UNIQUE/FK/CHECK constraint as
  `pg_get_constraintdef/1` renders it, and every index as `pg_indexes`
  renders it, with the schema qualifier stripped from both sides. A
  mismatch here means a fresh install after core drops these tables from
  its baseline would get a different schema than every existing host.

  `async: false` — DDL in a scratch schema on the shared sandbox connection;
  it rolls back with the test transaction.
  """

  @prefix "pkpubparity_host"

  setup do
    Repo.query!("CREATE SCHEMA IF NOT EXISTS #{@prefix}")
    Repo.query!("CREATE TABLE #{@prefix}.phoenix_kit_users (uuid uuid PRIMARY KEY)")

    Helpers.ensure_extension!(Repo, "pgcrypto")
    Helpers.ensure_uuid_v7_function(Repo, @prefix)

    :ok
  end

  test "V1 built into an empty schema matches core's public tables, catalog row for catalog row" do
    Migrations.up_statements(@prefix, 1) |> Enum.each(&Repo.query!/1)

    core = catalog_shape("public")
    v1 = catalog_shape(@prefix)

    # Guard against a vacuous pass: 7 tables' worth of columns, 20
    # constraints (7 PK + 1 UNIQUE + 12 FK) and 30 indexes (22 + the 8
    # constraint-backing ones).
    assert Enum.count(core, &match?({:constraint, _, _}, &1)) == 20
    assert Enum.count(core, &match?({:index, _, _}, &1)) == 30

    assert v1 -- core == []
    assert core -- v1 == []
  end

  test "a second run into the same schema changes nothing" do
    Migrations.up_statements(@prefix, 1) |> Enum.each(&Repo.query!/1)
    first = catalog_shape(@prefix)

    Migrations.up_statements(@prefix, 1) |> Enum.each(&Repo.query!/1)
    assert catalog_shape(@prefix) == first
  end

  defp catalog_shape(schema) do
    strip = &String.replace(&1 || "", "#{schema}.", "")

    columns =
      Repo.query!(
        """
        SELECT table_name, column_name, data_type, character_maximum_length,
               is_nullable, column_default
        FROM information_schema.columns
        WHERE table_schema = $1 AND table_name LIKE 'phoenix_kit_publishing_%'
        """,
        [schema]
      ).rows
      |> Enum.map(fn [table, column, type, width, nullable, default] ->
        {:column, table, {column, type, width, nullable, strip.(default)}}
      end)

    constraints =
      Repo.query!(
        """
        SELECT c.relname, pg_get_constraintdef(con.oid)
        FROM pg_constraint con
        JOIN pg_class c ON c.oid = con.conrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = $1 AND c.relname LIKE 'phoenix_kit_publishing_%'
          AND con.contype IN ('p', 'u', 'f', 'c')
        """,
        [schema]
      ).rows
      |> Enum.map(fn [table, definition] -> {:constraint, table, strip.(definition)} end)

    indexes =
      Repo.query!(
        """
        SELECT tablename, indexdef FROM pg_indexes
        WHERE schemaname = $1 AND tablename LIKE 'phoenix_kit_publishing_%'
        """,
        [schema]
      ).rows
      |> Enum.map(fn [table, definition] -> {:index, table, strip.(definition)} end)

    Enum.sort(columns ++ constraints ++ indexes)
  end
end
