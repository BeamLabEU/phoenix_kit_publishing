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

  describe "version labels" do
    alias PhoenixKit.Modules.Publishing.PublishingVersion

    test "round-trip, trimmed and capped; blank removes it; other saves leave it" do
      {slug, post, read} = published_post()
      assert read.metadata.version_label == nil

      {:ok, saved} =
        Posts.update_post(slug, read, %{"version_label" => "  Billing   0.27 "}, %{})

      assert saved.metadata.version_label == "Billing 0.27"
      assert saved.version_labels == %{1 => "Billing 0.27"}
      assert DBStorage.get_version(post.uuid, 1).data["label"] == "Billing 0.27"

      {:ok, kept} = Posts.update_post(slug, saved, %{"title" => "Renamed"}, %{})
      assert kept.metadata.version_label == "Billing 0.27"

      {:ok, long} =
        Posts.update_post(slug, kept, %{"version_label" => String.duplicate("x", 80)}, %{})

      assert String.length(long.metadata.version_label) == 60

      {:ok, cleared} = Posts.update_post(slug, long, %{"version_label" => " "}, %{})
      assert cleared.metadata.version_label == nil
      refute Map.has_key?(DBStorage.get_version(post.uuid, 1).data, "label")

      assert PublishingVersion.normalize_label(42) == nil
    end

    test "a new version made from a labelled one starts without its label" do
      {slug, post, read} = published_post()
      {:ok, _} = Posts.update_post(slug, read, %{"version_label" => "Billing 0.27"}, %{})

      {:ok, _} = Versions.create_version_from(slug, post.uuid, 1)
      {:ok, v2} = Publishing.read_post_by_uuid(post.uuid, "en", 2)

      assert v2.metadata.version_label == nil
      assert v2.version_labels == %{1 => "Billing 0.27"}
    end
  end
end
