defmodule PhoenixKit.Modules.Publishing.CrossGroupScopeTest do
  @moduledoc """
  Group-scoped mutations take the group from the page the caller is on and
  the uuid from the event they sent. Nothing used to check the two against
  each other — the lookup was by uuid alone — so naming group A while
  passing a group B uuid trashed, restored, published or unpublished B's
  post. Post uuids aren't secret; the public comment form renders one.

  Publishing someone else's draft is the sharp end: it makes unpublished
  work public. The quieter half is that the group decides which cache to
  rebuild, which topic to broadcast on, and what the audit row says the
  actor touched, so the wrong group gets all three.
  """

  use PhoenixKitPublishing.DataCase, async: false

  alias PhoenixKit.Modules.Publishing.DBStorage
  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.Posts
  alias PhoenixKit.Modules.Publishing.TranslationManager
  alias PhoenixKit.Modules.Publishing.Versions

  setup do
    n = System.unique_integer([:positive])
    {:ok, attacker} = Groups.add_group("scopeA-#{n}", mode: "slug")
    {:ok, victim_group} = Groups.add_group("scopeB-#{n}", mode: "slug")

    {:ok, victim} =
      Posts.create_post(victim_group["slug"], %{
        title: "Victim",
        slug: "victim",
        content: "unshipped"
      })

    %{other: attacker["slug"], home: victim_group["slug"], post: victim}
  end

  test "another group's slug cannot trash or restore a post", ctx do
    assert {:error, :not_found} = Posts.trash_post(ctx.other, ctx.post.uuid)
    assert is_nil(DBStorage.get_post_by_uuid(ctx.post.uuid).trashed_at)

    {:ok, _} = Posts.trash_post(ctx.home, ctx.post.uuid)
    assert {:error, :not_found} = Posts.restore_post(ctx.other, ctx.post.uuid)
    refute is_nil(DBStorage.get_post_by_uuid(ctx.post.uuid).trashed_at)
  end

  test "another group's slug cannot publish a draft", ctx do
    assert {:error, :not_found} = Versions.publish_version(ctx.other, ctx.post.uuid, 1)
    assert is_nil(DBStorage.get_post_by_uuid(ctx.post.uuid).active_version_uuid)
  end

  test "another group's slug cannot unpublish or delete a version", ctx do
    :ok = Versions.publish_version(ctx.home, ctx.post.uuid, 1)

    assert {:error, :not_found} = Versions.unpublish_post(ctx.other, ctx.post.uuid)
    refute is_nil(DBStorage.get_post_by_uuid(ctx.post.uuid).active_version_uuid)

    assert {:error, :not_found} = Versions.delete_version(ctx.other, ctx.post.uuid, 1)
  end

  test "the post's own group still works", ctx do
    assert :ok = Versions.publish_version(ctx.home, ctx.post.uuid, 1)
    refute is_nil(DBStorage.get_post_by_uuid(ctx.post.uuid).active_version_uuid)
    assert :ok = Versions.unpublish_post(ctx.home, ctx.post.uuid)
  end

  test "a malformed uuid is rejected rather than raising", ctx do
    assert {:error, :not_found} = Posts.trash_post(ctx.home, "not-a-uuid")
  end

  test "another group's slug cannot clear or delete a translation", ctx do
    assert {:error, _} =
             TranslationManager.clear_translation(
               ctx.other,
               ctx.post.uuid,
               "en"
             )

    assert {:error, _} =
             TranslationManager.delete_language(
               ctx.other,
               ctx.post.uuid,
               "en"
             )
  end

  test "a keyword list in the version position is refused, not bound to it", ctx do
    # `version \\ nil, opts \\ []` means a 4-arg call binds its last argument
    # to VERSION. An old-shape `clear_translation(g, u, l, actor_uuid: x)` would
    # have silently become "clear version [actor_uuid: x]" and cleared nothing.
    assert_raise FunctionClauseError, fn ->
      TranslationManager.clear_translation(
        ctx.home,
        ctx.post.uuid,
        "en",
        actor_uuid: "someone"
      )
    end
  end
end
