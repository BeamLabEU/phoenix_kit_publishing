defmodule PhoenixKit.Modules.Publishing.AdminListingLiveTitleTest do
  @moduledoc """
  Pins the maintainer's 2026-07-27 call: the admin group listing shows a
  published post by its LIVE (active published) version — title, status,
  and publish date — even when newer draft revisions exist. The
  per-language/per-version maps stay latest-version for editing context.
  """

  use PhoenixKitPublishing.DataCase, async: false

  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.DBStorage
  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.Posts
  alias PhoenixKit.Modules.Publishing.Versions

  defp unique_name, do: "lvt-#{System.unique_integer([:positive])}"

  test "a published post with a newer, differently-titled draft shows the live title" do
    {:ok, group} = Groups.add_group(unique_name(), mode: "slug")
    slug = group["slug"]

    {:ok, post} =
      Posts.create_post(slug, %{
        title: "Live Title",
        slug: "live-post",
        content: "Published body."
      })

    :ok = Versions.publish_version(slug, post.uuid, 1)

    # A newer draft revision with a different working title.
    {:ok, _v2} = Versions.create_version_from(slug, post.uuid, 1)

    {:ok, draft} = Publishing.read_post_by_uuid(post.uuid, "en", 2)

    {:ok, _} =
      Posts.update_post(slug, draft, %{"title" => "Draft Working Title", "version" => 2}, %{})

    [mapped] = DBStorage.list_posts_with_metadata(slug)

    # Card-level truth = the live version.
    assert mapped.metadata.title == "Live Title"
    assert mapped.metadata.status == "published"
    # Edit links pin this: published posts open the live version.
    assert mapped.live_version == 1

    # Editing context stays latest-version: the mapped revision and the
    # per-language titles reflect the draft.
    assert mapped.version == 2
    assert mapped.language_titles[mapped.language] == "Draft Working Title"
  end

  test "an unpublished post still shows its latest draft title" do
    {:ok, group} = Groups.add_group(unique_name(), mode: "slug")

    {:ok, _post} =
      Posts.create_post(group["slug"], %{title: "Only Draft", slug: "draft-post", content: "x"})

    [mapped] = DBStorage.list_posts_with_metadata(group["slug"])
    assert mapped.metadata.title == "Only Draft"
    assert mapped.metadata.status == "draft"
    # No live version → edit links open the newest revision (no ?v= pin).
    refute Map.has_key?(mapped, :live_version)
  end
end
