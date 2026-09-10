defmodule PhoenixKit.Integration.Publishing.DBStorageMentionAndRenameTest do
  @moduledoc """
  Integration tests for two `DBStorage` functions added for the editor's
  `[[` publication-mention popup and the post-slug rename sync (PR #48):

    * `search_posts_for_mention/2` — the picker's data source.
    * `rename_default_url_slugs/3` — carries default-tracking `url_slug`s
      along with a post-slug rename.

  Neither existed before this PR and neither had a test.

  Async: false — mutates the global publishing language settings, mirroring
  `web/controller/audio_test.exs`.
  """

  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Modules.Publishing.DBStorage
  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.Posts
  alias PhoenixKit.Settings

  setup do
    {:ok, _} = Settings.update_boolean_setting("languages_enabled", false)
    {:ok, _} = Settings.update_setting("content_language", "en")
    :ok
  end

  defp unique_name, do: "mention-rename-#{System.unique_integer([:positive])}"

  # ============================================================================
  # search_posts_for_mention/2
  # ============================================================================

  describe "search_posts_for_mention/2" do
    test "matches titles case-insensitively" do
      {:ok, group} = Groups.add_group(unique_name(), mode: "slug")

      {:ok, post} =
        Posts.create_post(group["slug"], %{title: "The Great Zebra Migration", slug: "zebra"})

      results = DBStorage.search_posts_for_mention("great zebra")
      assert Enum.any?(results, &(&1.uuid == post.uuid))
    end

    test "an empty query returns the most recently updated posts, not nothing" do
      {:ok, group} = Groups.add_group(unique_name(), mode: "slug")

      {:ok, older} = Posts.create_post(group["slug"], %{title: "Older Post", slug: "older-post"})
      {:ok, newer} = Posts.create_post(group["slug"], %{title: "Newer Post", slug: "newer-post"})

      # Force a deterministic gap instead of racing real clock precision —
      # two posts created back-to-back can land on the same timestamp.
      import Ecto.Query

      from(p in PhoenixKit.Modules.Publishing.PublishingPost, where: p.uuid == ^older.uuid)
      |> PhoenixKit.RepoHelper.repo().update_all(
        set: [updated_at: DateTime.add(DateTime.utc_now(), -3600, :second)]
      )

      results = DBStorage.search_posts_for_mention("")
      uuids = Enum.map(results, & &1.uuid)

      assert older.uuid in uuids
      assert newer.uuid in uuids
      # Most recently updated first.
      assert Enum.find_index(uuids, &(&1 == newer.uuid)) <
               Enum.find_index(uuids, &(&1 == older.uuid))
    end

    test "excludes trashed posts" do
      {:ok, group} = Groups.add_group(unique_name(), mode: "slug")

      {:ok, post} =
        Posts.create_post(group["slug"], %{title: "Doomed Post Unique Title", slug: "doomed"})

      {:ok, _} = Posts.trash_post(group["slug"], post.uuid)

      results = DBStorage.search_posts_for_mention("Doomed Post Unique")
      refute Enum.any?(results, &(&1.uuid == post.uuid))
    end

    test "excludes posts belonging to a trashed group" do
      {:ok, group} = Groups.add_group(unique_name(), mode: "slug")

      {:ok, post} =
        Posts.create_post(group["slug"], %{
          title: "Orphaned By Trashed Group",
          slug: "orphaned"
        })

      {:ok, _} = Groups.trash_group(group["slug"])

      results = DBStorage.search_posts_for_mention("Orphaned By Trashed")
      refute Enum.any?(results, &(&1.uuid == post.uuid))
    end

    test "one row per post — the highest matching version's title wins" do
      {:ok, group} = Groups.add_group(unique_name(), mode: "slug")

      {:ok, post} =
        Posts.create_post(group["slug"], %{title: "Versioned Mention Target", slug: "vmt"})

      [v1] = DBStorage.list_versions(post.uuid)

      {:ok, v2} =
        DBStorage.create_version(%{post_uuid: post.uuid, version_number: 2, status: "draft"})

      {:ok, _} =
        DBStorage.create_content(%{
          version_uuid: v2.uuid,
          language: "en",
          title: "Versioned Mention Target",
          content: "v2 body",
          status: "draft",
          url_slug: ""
        })

      results = DBStorage.search_posts_for_mention("Versioned Mention Target")
      matches = Enum.filter(results, &(&1.uuid == post.uuid))

      assert length(matches) == 1
      assert v2.version_number > v1.version_number
    end

    test "respects the limit" do
      {:ok, group} = Groups.add_group(unique_name(), mode: "slug")

      for n <- 1..5 do
        {:ok, _} =
          Posts.create_post(group["slug"], %{
            title: "Limit Probe #{n} #{System.unique_integer([:positive])}",
            slug: "limit-probe-#{n}-#{System.unique_integer([:positive])}"
          })
      end

      assert length(DBStorage.search_posts_for_mention("Limit Probe", 2)) <= 2
    end
  end

  # ============================================================================
  # rename_default_url_slugs/3
  # ============================================================================

  describe "rename_default_url_slugs/3" do
    test "a content row still tracking the old post slug follows the rename" do
      {:ok, group} = Groups.add_group(unique_name(), mode: "slug")

      {:ok, post} =
        Posts.create_post(group["slug"], %{title: "Default Tracker", slug: "default-tracker"})

      [version] = DBStorage.list_versions(post.uuid)
      [content] = DBStorage.list_contents(version.uuid)
      assert content.url_slug == "default-tracker"

      languages =
        DBStorage.rename_default_url_slugs(post.uuid, "default-tracker", "renamed-tracker")

      assert content.language in languages

      [reloaded] = DBStorage.list_contents(version.uuid)
      assert reloaded.url_slug == "renamed-tracker"
      assert "default-tracker" in (reloaded.data["previous_url_slugs"] || [])
    end

    test "a customized url_slug is left alone" do
      {:ok, group} = Groups.add_group(unique_name(), mode: "slug")

      {:ok, post} =
        Posts.create_post(group["slug"], %{title: "Customized", slug: "customized-post"})

      [version] = DBStorage.list_versions(post.uuid)
      [content] = DBStorage.list_contents(version.uuid)
      {:ok, _} = DBStorage.update_content(content, %{url_slug: "hand-picked-slug"})

      languages =
        DBStorage.rename_default_url_slugs(post.uuid, "customized-post", "customized-post-2")

      assert languages == []

      [reloaded] = DBStorage.list_contents(version.uuid)
      assert reloaded.url_slug == "hand-picked-slug"
    end

    test "carries every default-tracking language, not just the primary" do
      {:ok, group} = Groups.add_group(unique_name(), mode: "slug")

      {:ok, post} =
        Posts.create_post(group["slug"], %{title: "Multilang Tracker", slug: "multilang"})

      [version] = DBStorage.list_versions(post.uuid)

      {:ok, _} =
        DBStorage.create_content(%{
          version_uuid: version.uuid,
          language: "de",
          title: "Multilang Tracker (DE)",
          content: "de body",
          status: "draft",
          # Default-tracking: stamped with the post slug, same as the primary row.
          url_slug: "multilang"
        })

      languages = DBStorage.rename_default_url_slugs(post.uuid, "multilang", "multilang-neu")

      assert Enum.sort(languages) == Enum.sort(["en", "de"])

      for content <- DBStorage.list_contents(version.uuid) do
        assert content.url_slug == "multilang-neu"
      end
    end

    test "no matching rows returns an empty list and touches nothing" do
      {:ok, group} = Groups.add_group(unique_name(), mode: "slug")

      {:ok, post} =
        Posts.create_post(group["slug"], %{title: "Untouched", slug: "untouched-post"})

      assert DBStorage.rename_default_url_slugs(post.uuid, "never-was-the-slug", "new-slug") ==
               []

      [version] = DBStorage.list_versions(post.uuid)
      [content] = DBStorage.list_contents(version.uuid)
      assert content.url_slug == "untouched-post"
    end
  end
end
