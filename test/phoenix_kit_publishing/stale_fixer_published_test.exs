defmodule PhoenixKit.Modules.Publishing.StaleFixerPublishedTest do
  @moduledoc """
  The duplicate-published heal keeps the version the post points at. Keeping
  the highest number archived the live version beside a stray published newer
  one, and the next read cleared the now-stale pointer and demoted the other:
  two reads took a published post down.
  """

  use PhoenixKitPublishing.DataCase, async: false

  import PhoenixKitPublishing.Test.MediaFixtures

  alias PhoenixKit.Modules.Publishing.DBStorage
  alias PhoenixKit.Modules.Publishing.StaleFixer

  defp status(post, number), do: DBStorage.get_version(post.uuid, number).status

  test "the pointer's version stays published and the stray one is archived" do
    post = post!(group!("Dupes"), versions: 3)
    v2 = DBStorage.get_version(post.uuid, 2)
    v3 = DBStorage.get_version(post.uuid, 3)

    {:ok, _} = DBStorage.update_version(v2, %{status: "published"})
    {:ok, _} = DBStorage.update_version(v3, %{status: "published"})
    {:ok, post} = DBStorage.update_post(post, %{active_version_uuid: v2.uuid})

    StaleFixer.fix_multiple_published_versions(post)

    assert status(post, 2) == "published"
    assert status(post, 3) == "archived"
    assert DBStorage.get_post_by_uuid(post.uuid).active_version_uuid == v2.uuid

    # A read changed what is published: the audit trail says so.
    assert_activity_logged("publishing.version.duplicate_archived", resource_uuid: v3.uuid)
  end

  test "without a pointer among them the highest number is kept" do
    post = post!(group!("Dupes"), versions: 3)

    for n <- [2, 3] do
      {:ok, _} =
        DBStorage.update_version(DBStorage.get_version(post.uuid, n), %{status: "published"})
    end

    StaleFixer.fix_multiple_published_versions(post)

    assert status(post, 3) == "published"
    assert status(post, 2) == "archived"
  end
end
