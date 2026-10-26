defmodule PhoenixKit.Modules.Publishing.FileReferencesTest do
  @moduledoc """
  The file references this module hands to core's orphan-file check
  (`PhoenixKit.Modules.Publishing.FileReferences`): the right tables, SQL that runs, and the very SQL
  core's own built-in list holds for them, so moving the check changes nothing.

  Needs core's `Storage.builtin_file_references/0`, from the first core release
  after 2.64.1; against an older core the tests are excluded.
  """
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias Ecto.Query.DynamicExpr
  alias PhoenixKit.Migrations.ModuleOwnedTables
  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.FileReferences
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKitPublishing.Test.Repo

  @moduletag :integration
  @moduletag :requires_core_file_references

  @tables [
    "phoenix_kit_publishing_contents",
    "phoenix_kit_publishing_versions"
  ]

  setup do
    :ok = Sandbox.checkout(Repo)
  end

  defp sql(condition) do
    query = from(f in StorageFile, where: ^condition)
    SQL.to_sql(:all, Repo, query)
  end

  test "names the tables of this module that hold a file reference, and only those" do
    pairs = FileReferences.pairs()

    assert pairs |> Enum.map(&elem(&1, 0)) |> Enum.sort() == @tables

    assert Enum.all?(pairs, fn {table, condition} ->
             is_binary(table) and match?(%DynamicExpr{}, condition)
           end)
  end

  test "PhoenixKit.Modules.Publishing.file_references/0 is the same list" do
    assert Publishing.file_references() == FileReferences.pairs()
  end

  test "leaves out no table core's built-in list checks for this module" do
    mine = Enum.map(FileReferences.pairs(), &elem(&1, 0))

    for {table, _condition} <- Storage.builtin_file_references(),
        ModuleOwnedTables.owner(table) == :phoenix_kit_publishing or table in @tables do
      assert table in mine, "core checks #{table} and this module's list does not"
    end
  end

  test "each pair renders the same SQL as core's built-in one" do
    builtin = Map.new(Storage.builtin_file_references())

    for {table, condition} <- FileReferences.pairs() do
      assert sql(condition) == sql(Map.fetch!(builtin, table)), "SQL differs for #{table}"
    end
  end

  test "each condition runs against the database" do
    for {table, condition} <- FileReferences.pairs() do
      query = from(f in StorageFile, where: ^condition, select: count(f.uuid))
      assert is_integer(Repo.one(query)), "#{table} did not run"
    end
  end
end
