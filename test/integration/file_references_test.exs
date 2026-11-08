defmodule PhoenixKit.Modules.Publishing.FileReferencesTest do
  @moduledoc """
  The file references this module hands to core's orphan-file check
  (`PhoenixKit.Modules.Publishing.FileReferences`): the right tables, SQL that runs, the very
  SQL core's own built-in list holds for them (core's copy steps aside while this module
  supplies one), and every place a post names a file.
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
  alias PhoenixKitPublishing.Test.MediaFixtures
  alias PhoenixKitPublishing.Test.Repo

  @moduletag :integration

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

    assert pairs |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort() == @tables

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

  # Core's copy steps aside while this module supplies a list, so this list must
  # hold what core's did, unchanged; the other pairs add what core's never had.
  test "holds core's built-in pair for each table, verbatim" do
    mine = Enum.map(FileReferences.pairs(), fn {table, condition} -> {table, sql(condition)} end)

    for {table, condition} <- Storage.builtin_file_references(), table in @tables do
      assert {table, sql(condition)} in mine, "core's check for #{table} is missing"
    end
  end

  test "each condition runs against the database" do
    for {table, condition} <- FileReferences.pairs() do
      query = from(f in StorageFile, where: ^condition, select: count(f.uuid))
      assert is_integer(Repo.one(query)), "#{table} did not run"
    end
  end

  defp orphan?(file) do
    %{phoenix_kit_publishing: {:ok, FileReferences.pairs()}}
    |> Storage.orphaned_files_query()
    |> Ecto.Query.where([f], f.uuid == ^file.uuid)
    |> Repo.exists?()
  end

  describe "a file a post names is not an orphan" do
    setup do
      %{group: MediaFixtures.group!("Refs"), stored: MediaFixtures.file!()}
    end

    test "nothing names it: an orphan", %{group: group, stored: file} do
      MediaFixtures.post!(group, contents: [{"en", "no files here", %{}}])
      assert orphan?(file)
    end

    test "a version's featured image", %{group: group, stored: file} do
      MediaFixtures.post!(group, version_data: %{"featured_image_uuid" => file.uuid})
      refute orphan?(file)
    end

    test "a version's audio", %{group: group, stored: file} do
      MediaFixtures.post!(group, version_data: %{"audio_uuid" => file.uuid})
      refute orphan?(file)
    end

    test "a content row's OG image and legacy featured_image_id", %{group: group, stored: file} do
      MediaFixtures.post!(group, contents: [{"en", "", %{"og" => %{"image_uuid" => file.uuid}}}])
      refute orphan?(file)

      other = MediaFixtures.file!()
      MediaFixtures.post!(group, contents: [{"en", "", %{"featured_image_id" => other.uuid}}])
      refute orphan?(other)
    end

    test "an <Image> component in the body", %{group: group, stored: file} do
      body = ~s(Intro\n\n<Image file_uuid="#{String.upcase(file.uuid)}" alt="x"/>)
      MediaFixtures.post!(group, contents: [{"en", body, %{}}])
      refute orphan?(file)
    end

    test "a baked /file/<uuid>/ URL in the body", %{group: group, stored: file} do
      MediaFixtures.post!(group, contents: [{"en", "![x](/file/#{file.uuid}/large/abc)", %{}}])
      refute orphan?(file)
    end

    test "a trashed post's body still counts", %{group: group, stored: file} do
      MediaFixtures.post!(group,
        trashed_at: DateTime.utc_now(),
        contents: [{"en", ~s(<Audio file_uuid='#{file.uuid}'/>), %{}}]
      )

      refute orphan?(file)
    end
  end
end
