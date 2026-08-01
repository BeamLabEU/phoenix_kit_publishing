defmodule PhoenixKit.Modules.Publishing.VersionCategoriesTest do
  @moduledoc """
  Categories belong to a version, not to a post.

  A post's subject changes as it is revised, and a reader looking at `?v=2`
  should see how v2 was filed rather than how the live version is filed now.
  That means three things have to hold: a new version inherits the filing it
  was branched from, changing one version doesn't touch its siblings, and the
  upgrade from the old post-level table doesn't lose anybody's archive.
  """

  use PhoenixKitPublishing.DataCase, async: false

  alias PhoenixKit.Modules.Publishing.Categories
  alias PhoenixKit.Modules.Publishing.DBStorage
  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.Posts
  alias PhoenixKit.Modules.Publishing.PublishingPostCategory
  alias PhoenixKit.Modules.Publishing.PublishingVersion
  alias PhoenixKit.Modules.Publishing.Versions
  alias PhoenixKitPublishing.Test.Repo, as: TestRepo

  setup do
    slug = "vercat-#{System.unique_integer([:positive])}"
    {:ok, group} = Groups.add_group(slug, mode: "slug")
    {:ok, post} = Posts.create_post(slug, %{title: "Filed", slug: "filed", content: "Body"})
    {:ok, news} = Categories.create_category(slug, %{"name" => "News"})
    {:ok, guides} = Categories.create_category(slug, %{"name" => "Guides"})

    %{slug: slug, group: group, post: post, news: news, guides: guides}
  end

  defp version_categories(post_uuid, number) do
    post_uuid
    |> DBStorage.get_version(number)
    |> PublishingVersion.get_category_uuids()
  end

  test "a new version inherits the filing it was branched from", ctx do
    {:ok, _} = Categories.replace_post_categories(ctx.post.uuid, [ctx.news.uuid])

    {:ok, _} = Versions.create_version_from(ctx.slug, ctx.post.uuid, 1)

    assert version_categories(ctx.post.uuid, 2) == [ctx.news.uuid],
           "a revision starts filed where its parent was, or every new version " <>
             "silently falls out of its archives"
  end

  test "refiling one version leaves the other alone", ctx do
    {:ok, _} = Categories.replace_post_categories(ctx.post.uuid, [ctx.news.uuid])
    {:ok, _} = Versions.create_version_from(ctx.slug, ctx.post.uuid, 1)

    # Refile v2 only — the whole point of making this version-level.
    v2 = DBStorage.get_version(ctx.post.uuid, 2)

    {:ok, _} =
      v2
      |> Ecto.Changeset.change(data: Map.put(v2.data, "category_uuids", [ctx.guides.uuid]))
      |> TestRepo.update()

    assert version_categories(ctx.post.uuid, 1) == [ctx.news.uuid]
    assert version_categories(ctx.post.uuid, 2) == [ctx.guides.uuid]
  end

  test "the post map carries the filing of the version it represents", ctx do
    {:ok, _} = Categories.replace_post_categories(ctx.post.uuid, [ctx.news.uuid])
    {:ok, _} = Versions.create_version_from(ctx.slug, ctx.post.uuid, 1)

    v2 = DBStorage.get_version(ctx.post.uuid, 2)

    {:ok, _} =
      v2
      |> Ecto.Changeset.change(data: Map.put(v2.data, "category_uuids", [ctx.guides.uuid]))
      |> TestRepo.update()

    {:ok, read_v1} = Posts.read_post(ctx.slug, ctx.post.uuid, nil, 1)
    {:ok, read_v2} = Posts.read_post(ctx.slug, ctx.post.uuid, nil, 2)

    assert read_v1.metadata.category_uuids == [ctx.news.uuid]
    assert read_v2.metadata.category_uuids == [ctx.guides.uuid]
  end

  test "legacy post-level rows are moved onto every version, then drained", ctx do
    {:ok, _} = Versions.create_version_from(ctx.slug, ctx.post.uuid, 1)

    # Simulate a site upgrading: filing exists ONLY as join rows, which is
    # all an older install has.
    for version_number <- [1, 2] do
      v = DBStorage.get_version(ctx.post.uuid, version_number)

      {:ok, _} =
        v
        |> Ecto.Changeset.change(data: Map.delete(v.data, "category_uuids"))
        |> TestRepo.update()
    end

    TestRepo.insert_all(PublishingPostCategory, [
      %{
        post_uuid: ctx.post.uuid,
        category_uuid: ctx.news.uuid,
        inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
      }
    ])

    assert Categories.backfill_version_categories(ctx.slug) == 2

    # Every version, not just the live one: the old model meant "whichever
    # version you are looking at".
    assert version_categories(ctx.post.uuid, 1) == [ctx.news.uuid]
    assert version_categories(ctx.post.uuid, 2) == [ctx.news.uuid]

    # Drained, so this is self-limiting rather than re-running forever.
    assert TestRepo.aggregate(PublishingPostCategory, :count) == 0
    assert Categories.backfill_version_categories(ctx.slug) == 0
  end

  test "the backfill sets the one key and leaves the rest of the version alone", ctx do
    # It used to read each version, put the key into the map it had read, and
    # write the whole map back. Anything saved between the read and the write
    # was inside that map in its old form, so the write reverted it — silently,
    # and on every regenerate for as long as the legacy rows survived.
    v = DBStorage.get_version(ctx.post.uuid, 1)

    neighbours = %{
      "featured_image_uuid" => "keep-me",
      "tags" => ["a", "b"],
      "seo_title" => "Kept",
      "excerpt" => "Also kept"
    }

    {:ok, _} =
      v
      |> Ecto.Changeset.change(
        data: v.data |> Map.delete("category_uuids") |> Map.merge(neighbours)
      )
      |> TestRepo.update()

    TestRepo.insert_all(PublishingPostCategory, [
      %{
        post_uuid: ctx.post.uuid,
        category_uuid: ctx.news.uuid,
        inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
      }
    ])

    assert Categories.backfill_version_categories(ctx.slug) == 1
    assert version_categories(ctx.post.uuid, 1) == [ctx.news.uuid]

    after_data = DBStorage.get_version(ctx.post.uuid, 1).data

    for {key, value} <- neighbours do
      assert after_data[key] == value, "backfill clobbered #{key}"
    end
  end

  test "the backfill never overwrites a filing that is already there", ctx do
    {:ok, _} = Categories.replace_post_categories(ctx.post.uuid, [ctx.guides.uuid])

    TestRepo.insert_all(PublishingPostCategory, [
      %{
        post_uuid: ctx.post.uuid,
        category_uuid: ctx.news.uuid,
        inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
      }
    ])

    Categories.backfill_version_categories(ctx.slug)

    assert version_categories(ctx.post.uuid, 1) == [ctx.guides.uuid],
           "a stale join row must never win over a real edit"
  end

  test "an editor that saved before the move ran doesn't lose the filing", ctx do
    # The exact sequence that bit the demo post. The editor builds its form
    # from version.data, which during the migration window has no categories
    # in it — they are still in the old table — so an autosave writes back an
    # empty list. If the move then treats that as a deliberate answer, one
    # keystroke silently unfiles the post and nothing says so.
    v1 = DBStorage.get_version(ctx.post.uuid, 1)

    {:ok, _} =
      v1
      |> Ecto.Changeset.change(data: Map.put(v1.data, "category_uuids", []))
      |> TestRepo.update()

    TestRepo.insert_all(PublishingPostCategory, [
      %{
        post_uuid: ctx.post.uuid,
        category_uuid: ctx.news.uuid,
        inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
      }
    ])

    Categories.backfill_version_categories(ctx.slug)

    assert version_categories(ctx.post.uuid, 1) == [ctx.news.uuid]

    # And once the move is done, an empty list IS the answer — the legacy
    # rows are gone, so there is nothing to resurrect.
    {:ok, _} = Categories.replace_post_categories(ctx.post.uuid, [])
    Categories.backfill_version_categories(ctx.slug)
    assert version_categories(ctx.post.uuid, 1) == []
  end

  test "deleting a category unfiles it from versions", ctx do
    {:ok, _} = Categories.replace_post_categories(ctx.post.uuid, [ctx.news.uuid, ctx.guides.uuid])
    {:ok, _} = Categories.delete_category(ctx.news.uuid)

    # No foreign key reaches into JSONB, so this is hand-rolled and worth
    # pinning: the survivor stays, the deleted one goes.
    assert version_categories(ctx.post.uuid, 1) == [ctx.guides.uuid]
  end

  test "counts come from the live version, not from drafts", ctx do
    :ok = Versions.publish_version(ctx.slug, ctx.post.uuid, 1)
    {:ok, _} = Categories.replace_post_categories(ctx.post.uuid, [ctx.news.uuid])

    # A draft refiled elsewhere must not move the public count until it is
    # published — otherwise the admin tree advertises an archive entry that
    # isn't there.
    {:ok, _} = Versions.create_version_from(ctx.slug, ctx.post.uuid, 1)
    v2 = DBStorage.get_version(ctx.post.uuid, 2)

    {:ok, _} =
      v2
      |> Ecto.Changeset.change(data: Map.put(v2.data, "category_uuids", [ctx.guides.uuid]))
      |> TestRepo.update()

    counts = Categories.published_post_counts(ctx.slug)

    assert Map.get(counts, ctx.news.uuid) == 1
    assert Map.get(counts, ctx.guides.uuid) == nil
  end
end
