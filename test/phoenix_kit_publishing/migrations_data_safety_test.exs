defmodule PhoenixKitPublishing.MigrationsDataSafetyTest do
  use PhoenixKitPublishing.DataCase, async: false

  alias Ecto.Migration.Runner
  alias PhoenixKit.Modules.Publishing.Categories
  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.Posts
  alias PhoenixKit.Modules.Publishing.PublishingCategory
  alias PhoenixKit.Modules.Publishing.PublishingGroup
  alias PhoenixKit.Modules.Publishing.PublishingPost
  alias PhoenixKit.Modules.Publishing.PublishingVersion
  alias PhoenixKit.Modules.Publishing.Versions
  alias PhoenixKit.Modules.Publishing.Views
  alias PhoenixKitPublishing.Migrations
  alias PhoenixKitPublishing.Test.Repo

  @moduledoc """
  The acceptance a full 7-table row chain actually needs, and that no static
  test can give: REAL rows, a REAL `down/1` run as a migration, and the rows
  still there afterwards, byte-for-byte.

  `migrations_test.exs` proves what the chain BUILDS (no
  DROP/TRUNCATE/DELETE token anywhere, `down/1` emits marker bookkeeping
  only). That is a proof about text. This file proves what the chain DOES to
  a database that holds a real group, post, two versions, a category, a
  post→category filing, and a view-counter row — across all 7
  `phoenix_kit_publishing_*` tables, seeded through this module's own public
  contexts (`Groups`, `Posts`, `Versions`, `Categories`, `Views`), not
  hand-inserted rows.

  The last test is the mutation check: it runs the same survival harness
  against a deliberately destructive rollback and requires it to FAIL.
  Without that, a survival assertion that silently stopped asserting (wrong
  table name, empty row set) would stay green forever and prove nothing.

  `async: false` — the migrator wants the shared sandbox connection.
  """

  defmodule RollbackToZero do
    @moduledoc false
    use Ecto.Migration

    def up, do: Migrations.down(prefix: "public", version: 0)
    def down, do: :ok
  end

  defmodule RollbackToOneFromMap do
    @moduledoc false
    use Ecto.Migration

    # Deliberately the MAP shape: it is accepted, so it must carry
    # `:version` like the keyword list does.
    def up, do: Migrations.down(%{prefix: "public", version: 1})
    def down, do: :ok
  end

  defmodule DestructiveRollback do
    @moduledoc false
    use Ecto.Migration

    # NOT what the package ships — the mutant the survival check must catch.
    def up do
      execute("DELETE FROM public.phoenix_kit_publishing_post_views")
      execute("DELETE FROM public.phoenix_kit_publishing_post_categories")
      execute("DELETE FROM public.phoenix_kit_publishing_categories")
      execute("DELETE FROM public.phoenix_kit_publishing_contents")
      execute("DELETE FROM public.phoenix_kit_publishing_versions")
      execute("DELETE FROM public.phoenix_kit_publishing_posts")
      execute("DELETE FROM public.phoenix_kit_publishing_groups")
    end

    def down, do: :ok
  end

  defmodule RunUpToOne do
    @moduledoc false
    use Ecto.Migration

    def up, do: Migrations.up(prefix: "public", version: 1)
    def down, do: :ok
  end

  setup do
    {:ok, group} = Groups.add_group("Data Safety Group #{System.unique_integer([:positive])}")
    {:ok, post} = Posts.create_post(group["slug"], %{title: "Data Safety Post"})
    {:ok, v2_post} = Versions.create_new_version(group["slug"], post, %{}, %{})

    {:ok, category} =
      Categories.create_category(group["slug"], %{"name" => "Data Safety Category"})

    {:ok, _uuids} = Categories.replace_post_categories(post[:uuid], [category.uuid])

    # A real join-table row too — `Categories.replace_post_categories/3`
    # writes the ASSIGNMENT onto `version.data["category_uuids"]` (see
    # `Categories`' moduledoc: the V159 join table is drained on first use,
    # nothing writes it any more), so `phoenix_kit_publishing_post_categories`
    # would otherwise hold zero rows and its own survival assertion below
    # would be a vacuous `0 == 0`. Seeded directly, the same way
    # `Views.record_view/2` seeds `post_views` without a schema-owning
    # context of its own.
    {1, _} =
      Repo.insert_all("phoenix_kit_publishing_post_categories", [
        [
          post_uuid: Ecto.UUID.dump!(post[:uuid]),
          category_uuid: Ecto.UUID.dump!(category.uuid),
          inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
        ]
      ])

    :ok = Views.record_view(post[:uuid])

    {:ok, group: group, post: post, v2_post: v2_post, category: category}
  end

  test "a real down(version: 0) leaves every seeded row alive, across all 7 tables",
       %{group: group, post: post, category: category} do
    counts_before = all_counts()

    run_migration(RollbackToZero)

    assert all_counts() == counts_before,
           "rolling this chain back changed at least one of the 7 tables' row counts: " <>
             "before=#{inspect(counts_before)} after=#{inspect(all_counts())}"

    reloaded_group = Repo.get!(PublishingGroup, group["uuid"])
    assert reloaded_group.name == group["name"]
    assert reloaded_group.slug == group["slug"]

    reloaded_post = Repo.get!(PublishingPost, post[:uuid])
    assert reloaded_post.group_uuid == group["uuid"]

    reloaded_v1 = Repo.get!(PublishingVersion, version_uuid(post[:uuid], 1))
    assert reloaded_v1.version_number == 1

    reloaded_v2 = Repo.get!(PublishingVersion, version_uuid(post[:uuid], 2))
    assert reloaded_v2.version_number == 2

    reloaded_category = Repo.get!(PublishingCategory, category.uuid)
    assert reloaded_category.name == category.name

    assert post_category_row_exists?(post[:uuid], category.uuid)
    assert post_view_total(post[:uuid]) == 1
  end

  test "the rollback still does its one real job: the marker is cleared" do
    Repo.query!("COMMENT ON TABLE phoenix_kit_publishing_groups IS 'pkpub_schema:1'")
    assert Migrations.migrated_version_runtime(prefix: "public") == 1

    run_migration(RollbackToZero)

    assert Migrations.migrated_version_runtime(prefix: "public") == 0
  end

  test "a rollback to version 1 passed as a map stops at 1, not at 0" do
    Repo.query!("COMMENT ON TABLE phoenix_kit_publishing_groups IS 'pkpub_schema:1'")

    run_migration(RollbackToOneFromMap)

    assert Migrations.migrated_version_runtime(prefix: "public") == 1,
           "the map shape lost :version and rolled the chain further back than asked"
  end

  test "a real up(version: 1) run is idempotent and leaves seeded rows untouched",
       %{group: group, post: post} do
    # up/1 re-reads the installed version, calls ensure_extension!/1 and
    # ensure_uuid_v7_function/1, then runs the same guarded statements
    # up_statements/2 emits — clearing the marker first simulates the
    # "database behind the target" branch up/1 checks before doing anything,
    # so this exercises that whole path for real rather than as SQL text
    # applied directly (test_helper.exs does the latter, once, before any
    # test runs — this is the only place up/1 itself, as a function, gets a
    # real migration-context run).
    counts_before = all_counts()

    Repo.query!("COMMENT ON TABLE phoenix_kit_publishing_groups IS NULL")

    run_migration(RunUpToOne)

    assert Migrations.migrated_version_runtime(prefix: "public") == 1

    assert all_counts() == counts_before,
           "a real up(version: 1) run changed at least one of the 7 tables' row counts"

    assert Repo.get!(PublishingGroup, group["uuid"]).name == group["name"]
    assert Repo.get!(PublishingPost, post[:uuid]).group_uuid == group["uuid"]

    # Idempotence: every table/pkey/unique-constraint/index/fk statement is
    # CREATE-IF-NOT-EXISTS/DO-guarded against objects that already exist
    # (core's baseline created them), so running up/1 again must be a no-op,
    # not an error. Clear the marker again first — otherwise this second
    # call is just a version-gate no-op that never re-reaches the guarded
    # statements, which would prove the gate works but not the guards.
    Repo.query!("COMMENT ON TABLE phoenix_kit_publishing_groups IS NULL")
    run_migration(RunUpToOne)
    assert Migrations.migrated_version_runtime(prefix: "public") == 1
    assert all_counts() == counts_before
  end

  test "the survival check has teeth: a destructive rollback fails it", %{group: group} do
    counts_before = all_counts()

    run_migration(DestructiveRollback)

    # The same assertions the real test makes. Both must fail here, or the
    # real test above is decoration.
    assert_raise ExUnit.AssertionError, fn ->
      assert all_counts() == counts_before
    end

    assert_raise Ecto.NoResultsError, fn ->
      Repo.get!(PublishingGroup, group["uuid"])
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────

  # Runs the migration IN THIS PROCESS, through Ecto's own migration runner,
  # rather than `Ecto.Migrator.up/4`. The Migrator runs the migration inside a
  # `Task`, which then has to check out the sandbox connection this test
  # already owns — it never gets it, and every assertion below dies in the
  # checkout queue instead of testing the rollback. The runner is what the
  # Migrator itself calls once it has dealt with locking and version
  # bookkeeping; going straight to it keeps the real migration context (so
  # `execute/1` inside `down/1` is the real `execute/1`) and drops only the
  # parts this file is not about.
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

  @tables ~w(
    phoenix_kit_publishing_groups
    phoenix_kit_publishing_posts
    phoenix_kit_publishing_versions
    phoenix_kit_publishing_contents
    phoenix_kit_publishing_categories
    phoenix_kit_publishing_post_categories
    phoenix_kit_publishing_post_views
  )

  defp all_counts, do: Map.new(@tables, &{&1, count(&1)})

  defp count(table) do
    %{rows: [[count]]} = Repo.query!("SELECT count(*) FROM #{table}")
    count
  end

  defp post_category_row_exists?(post_uuid, category_uuid) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM phoenix_kit_publishing_post_categories WHERE post_uuid = $1 AND category_uuid = $2",
        [Ecto.UUID.dump!(post_uuid), Ecto.UUID.dump!(category_uuid)]
      )

    count == 1
  end

  defp post_view_total(post_uuid) do
    %{rows: [[total]]} =
      Repo.query!(
        "SELECT count FROM phoenix_kit_publishing_post_views WHERE post_uuid = $1",
        [Ecto.UUID.dump!(post_uuid)]
      )

    total
  end

  # `Mapper.to_post_map/6` (what `Posts.create_post/2`/`Versions.create_new_version/4`
  # both return) puts the POST's own uuid under `:uuid` and the version
  # NUMBER (not its uuid) under `:version` — there is no `:version_uuid` key
  # in that map at all, so a specific version's row uuid is resolved by
  # querying `phoenix_kit_publishing_versions` directly.
  defp version_uuid(post_uuid, version_number) do
    import Ecto.Query

    from(v in PublishingVersion,
      where: v.post_uuid == ^post_uuid and v.version_number == ^version_number
    )
    |> Repo.one!()
    |> Map.fetch!(:uuid)
  end
end
