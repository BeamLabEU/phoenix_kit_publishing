defmodule PhoenixKit.Modules.Publishing.SlugRenameAtomicityTest do
  @moduledoc """
  A rename and the save it arrived with succeed or fail together.

  The slug used to be written before the transaction holding the rest of the
  save, so a save that failed its own validation still moved the post to its
  new address: the editor said the save failed while the old URL had already
  stopped working, and the previous-slug redirect that would have covered it
  is recorded by the part that rolled back.
  """

  use PhoenixKitPublishing.DataCase, async: false

  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.DBStorage
  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.Posts
  alias PhoenixKit.Modules.Publishing.Versions

  setup do
    slug = "atomic-#{System.unique_integer([:positive])}"
    {:ok, _} = Groups.add_group(slug, mode: "slug")

    {:ok, post} =
      Posts.create_post(slug, %{title: "Original", slug: "original", content: "body"})

    :ok = Versions.publish_version(slug, post.uuid, 1)
    {:ok, read} = Publishing.read_post_by_uuid(post.uuid, "en", 1)

    %{slug: slug, post: post, read: read}
  end

  test "a rename that arrives with a rejected save doesn't move the post", ctx do
    # Publishing with a blank primary title is refused, and the rename rides
    # along on that same save.
    result =
      Posts.update_post(
        ctx.slug,
        ctx.read,
        %{"slug" => "renamed", "title" => "", "status" => "published"},
        %{}
      )

    assert {:error, _} = result

    assert DBStorage.get_post_by_uuid(ctx.post.uuid).slug == "original",
           "the save was refused but the post had already moved"
  end

  test "a rename that arrives with an accepted save does move the post", ctx do
    {:ok, _} = Posts.update_post(ctx.slug, ctx.read, %{"slug" => "renamed"}, %{})

    assert DBStorage.get_post_by_uuid(ctx.post.uuid).slug == "renamed"
  end

  test "a save with no rename leaves the slug where it is", ctx do
    {:ok, _} = Posts.update_post(ctx.slug, ctx.read, %{"content" => "edited"}, %{})

    assert DBStorage.get_post_by_uuid(ctx.post.uuid).slug == "original"
  end
end
