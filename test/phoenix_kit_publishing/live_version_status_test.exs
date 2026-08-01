defmodule PhoenixKit.Modules.Publishing.LiveVersionStatusTest do
  @moduledoc """
  Which version is live is decided in one place — `publish_version/4` and
  `unpublish_post/3`, under the post row's lock, where the status and the
  pointer move together.

  A save can't be that place, because a save carries a whole form and a form
  is a snapshot of what the page knew when it loaded. Open a post in two
  languages, publish from one, and the other still holds `status => "draft"`;
  its next autosave used to write that back over the version the publish had
  just made live. The post then disagreed with itself: live by its pointer,
  draft by its status. The public page kept serving it (the join follows the
  pointer) while the admin list called it a draft, and `stale_fixer` won't
  repair that shape — it only heals a missing pointer.
  """

  use PhoenixKitPublishing.DataCase, async: false

  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.DBStorage
  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.Posts
  alias PhoenixKit.Modules.Publishing.Versions

  setup do
    slug = "livestat-#{System.unique_integer([:positive])}"
    {:ok, _} = Groups.add_group(slug, mode: "slug")
    {:ok, post} = Posts.create_post(slug, %{title: "S", slug: "s", content: "body"})

    %{slug: slug, post: post}
  end

  test "a stale form cannot demote the version it was published under", ctx do
    # The other tab's snapshot, taken while this was still a draft.
    {:ok, stale} = Publishing.read_post_by_uuid(ctx.post.uuid, "en", 1)
    assert stale.metadata[:status] == "draft"

    :ok = Versions.publish_version(ctx.slug, ctx.post.uuid, 1)

    {:ok, _} =
      Posts.update_post(ctx.slug, stale, %{"content" => "edited", "status" => "draft"}, %{})

    version = DBStorage.get_version(ctx.post.uuid, 1)
    post = DBStorage.get_post_by_uuid(ctx.post.uuid)

    assert version.status == "published", "a save took the live version off the air"
    assert post.active_version_uuid == version.uuid

    # The edit itself still landed — the guard drops the status, not the save.
    {:ok, read} = Publishing.read_post_by_uuid(ctx.post.uuid, "en", 1)
    assert read.content == "edited"
  end

  test "archiving the live version from a save is refused too", ctx do
    :ok = Versions.publish_version(ctx.slug, ctx.post.uuid, 1)
    {:ok, live} = Publishing.read_post_by_uuid(ctx.post.uuid, "en", 1)

    {:ok, _} = Posts.update_post(ctx.slug, live, %{"status" => "archived"}, %{})

    assert DBStorage.get_version(ctx.post.uuid, 1).status == "published"
  end

  test "a version that isn't live still takes any status a save gives it", ctx do
    :ok = Versions.publish_version(ctx.slug, ctx.post.uuid, 1)
    {:ok, _} = Versions.create_version_from(ctx.slug, ctx.post.uuid, 1)
    {:ok, v2} = Publishing.read_post_by_uuid(ctx.post.uuid, "en", 2)

    {:ok, _} = Posts.update_post(ctx.slug, v2, %{"status" => "archived"}, %{})

    assert DBStorage.get_version(ctx.post.uuid, 2).status == "archived"
    assert DBStorage.get_version(ctx.post.uuid, 1).status == "published"
  end

  test "unpublishing still works — it just has to go through the real door", ctx do
    :ok = Versions.publish_version(ctx.slug, ctx.post.uuid, 1)
    :ok = Versions.unpublish_post(ctx.slug, ctx.post.uuid, target_status: "archived")

    assert DBStorage.get_version(ctx.post.uuid, 1).status == "archived"
    assert is_nil(DBStorage.get_post_by_uuid(ctx.post.uuid).active_version_uuid)
  end
end
