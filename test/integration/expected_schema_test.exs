defmodule PhoenixKit.Modules.Publishing.Integration.ExpectedSchemaTest do
  @moduledoc """
  The generated manifest (`PhoenixKit.Modules.Publishing.ExpectedSchema`) agrees with what this
  module's chain builds, and repair uses it.

  The chain is built alone in a scratch schema
  (`PhoenixKit.TestSupport.ModuleChainCheck.build_alone/4`), then
  `PhoenixKit.Migrations.Repair` runs against that schema with this module's
  manifest. Regenerate the manifest after any change to the chain; see the header
  of `expected_schema.ex`. Excluded (`:requires_core_expected_schema`, see
  `test_helper.exs`) against a core that lacks the callback.
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKit.Migrations.Repair
  alias PhoenixKit.Modules.Publishing.ExpectedSchema
  alias PhoenixKit.TestSupport.ModuleChainCheck
  alias PhoenixKitPublishing.Test.Repo, as: Repo

  @moduletag :integration
  @moduletag :requires_core_expected_schema
  @moduletag timeout: :timer.minutes(3)

  @app :phoenix_kit_publishing
  @migrations PhoenixKitPublishing.Migrations
  @modules %{@app => %{manifest: ExpectedSchema, migrations: @migrations}}
  @known_gaps []

  setup do
    # Core's chain reads the repo from config while it builds.
    previous_repo = Application.get_env(:phoenix_kit, :repo)
    Application.put_env(:phoenix_kit, :repo, Repo)

    schema = "pkes_" <> Integer.to_string(System.unique_integer([:positive]))
    {:ok, tables} = ModuleChainCheck.build_alone(Repo, @migrations, schema)

    :ok = Sandbox.checkout(Repo)

    on_exit(fn ->
      if previous_repo,
        do: Application.put_env(:phoenix_kit, :repo, previous_repo),
        else: Application.delete_env(:phoenix_kit, :repo)

      Sandbox.mode(Repo, :auto)
      Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema}" CASCADE))
      Sandbox.mode(Repo, :manual)
    end)

    %{schema: schema, tables: tables}
  end

  defp module_findings(report) do
    report
    |> Repair.Report.findings()
    |> Enum.filter(&(&1[:module] && &1.object_id not in @known_gaps))
  end

  defp verify(schema) do
    {:ok, report} = Repair.verify(prefix: schema, repo: Repo, module_manifests: @modules)
    report
  end

  test "describes every table the chain builds, and nothing else", %{tables: tables} do
    manifest_tables =
      for %{class: :table, check: {:catalog, %{name: name}}} <- ExpectedSchema.objects("public"),
          do: name

    assert Enum.sort(manifest_tables) == Enum.sort(tables)
  end

  test "a freshly built chain has no findings", %{schema: schema} do
    assert [] = schema |> verify() |> module_findings()
  end

  test "every index and constraint the chain builds is in the manifest", %{
    schema: schema,
    tables: tables
  } do
    ids = MapSet.new(ExpectedSchema.objects(schema), & &1.id)

    %{rows: indexes} =
      Repo.query!(
        "SELECT indexname FROM pg_indexes WHERE schemaname = $1 AND tablename = ANY($2)",
        [schema, tables]
      )

    %{rows: constraints} =
      Repo.query!(
        """
        SELECT c.relname, con.conname FROM pg_constraint con
        JOIN pg_class c ON c.oid = con.conrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = $1 AND c.relname = ANY($2) AND con.contype <> 'n'
        """,
        [schema, tables]
      )

    # Some chains embed the schema in an index or constraint name; the manifest
    # carries the unprefixed name.
    unprefixed = &String.replace_prefix(&1, schema <> "_", "")

    for [name] <- indexes, name = unprefixed.(name) do
      assert MapSet.member?(ids, "index:#{name}") or pkey?(ids, name),
             "index #{name} is not in the manifest"
    end

    for [table, name] <- constraints, name = unprefixed.(name) do
      assert MapSet.member?(ids, "constraint:#{table}.#{name}"),
             "constraint #{table}.#{name} is not in the manifest"
    end
  end

  test "a missing column is found, then restored by repair", %{schema: schema, tables: tables} do
    # A nullable column no index or constraint touches, so dropping it is the
    # only change.
    %{rows: [[table, column] | _]} =
      Repo.query!(
        """
        SELECT c.relname, a.attname FROM pg_attribute a
        JOIN pg_class c ON c.oid = a.attrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = $1 AND c.relname = ANY($2) AND a.attnum > 0
          AND NOT a.attisdropped AND NOT a.attnotnull
          AND NOT EXISTS (SELECT 1 FROM pg_index i
                          WHERE i.indrelid = c.oid AND a.attnum = ANY(i.indkey))
          AND NOT EXISTS (SELECT 1 FROM pg_constraint k
                          WHERE k.conrelid = c.oid AND a.attnum = ANY(k.conkey))
        ORDER BY c.relname, a.attnum
        """,
        [schema, tables]
      )

    Repo.query!(~s(ALTER TABLE "#{schema}"."#{table}" DROP COLUMN "#{column}"))

    id = "column:#{table}.#{column}"

    assert [%{kind: :missing, module: @app, object_id: ^id}] =
             schema |> verify() |> module_findings()

    {:ok, _report} = Repair.repair(prefix: schema, repo: Repo, module_manifests: @modules)

    assert [] = schema |> verify() |> module_findings()
  end

  # A primary key or unique constraint's index is listed as the constraint.
  defp pkey?(ids, index_name) do
    Enum.any?(ids, &String.ends_with?(&1, "." <> index_name))
  end
end
