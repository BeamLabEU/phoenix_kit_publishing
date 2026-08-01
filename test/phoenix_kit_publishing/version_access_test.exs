defmodule PhoenixKit.Modules.Publishing.VersionAccessTest do
  @moduledoc """
  Pins `allow_version_access` — the per-post switch that lets readers open a
  published post's older versions at `?v=N`.

  The public route gated on it and the mapper read it, but for a long time
  NOTHING wrote it: the editor's toggle handler passed the param and
  `update_version_defaults/4` silently dropped it, so the setting could never
  be turned on. It was also unreachable from the UI. Both are fixed; these
  tests keep the write path honest.
  """

  use PhoenixKitPublishing.DataCase, async: false

  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.DBStorage
  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.Posts
  alias PhoenixKit.Modules.Publishing.Versions

  defp published_post do
    {:ok, group} =
      Groups.add_group("vaccess-#{System.unique_integer([:positive])}", mode: "slug")

    slug = group["slug"]
    {:ok, post} = Posts.create_post(slug, %{title: "Versioned", slug: "versioned", content: "b"})
    :ok = Versions.publish_version(slug, post.uuid, 1)
    {:ok, read} = Publishing.read_post_by_uuid(post.uuid, "en", 1)
    {slug, post, read}
  end

  test "round-trips through update_post, the version row, and the post map" do
    {slug, post, read} = published_post()

    refute read.metadata.allow_version_access

    {:ok, saved} = Posts.update_post(slug, read, %{"allow_version_access" => "true"}, %{})
    assert saved.metadata.allow_version_access == true
    assert DBStorage.get_version(post.uuid, 1).data["allow_version_access"] == true

    {:ok, off} = Posts.update_post(slug, saved, %{"allow_version_access" => "false"}, %{})
    assert off.metadata.allow_version_access == false
  end

  test "a save that doesn't carry the field leaves it untouched" do
    {slug, _post, read} = published_post()
    {:ok, on} = Posts.update_post(slug, read, %{"allow_version_access" => "true"}, %{})

    {:ok, after_title} = Posts.update_post(slug, on, %{"title" => "Renamed"}, %{})
    assert after_title.metadata.allow_version_access == true
  end
end
