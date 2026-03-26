defmodule PhoenixKit.Integration.Publishing.PostsTest do
  use PhoenixKit.DataCase, async: true

  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.Posts
  alias PhoenixKit.Modules.Publishing.Versions

  defp unique_name, do: "Posts Group #{System.unique_integer([:positive])}"

  defp create_group(mode) do
    {:ok, group} = Groups.add_group(unique_name(), mode: mode)
    group
  end

  # ============================================================================
  # create_post/2 — timestamp mode
  # ============================================================================

  describe "create_post/2 in timestamp mode" do
    test "creates post with auto-generated timestamp" do
      group = create_group("timestamp")
      {:ok, post} = Posts.create_post(group["slug"], %{})

      assert post[:uuid]
      assert post[:date]
      assert post[:time]
      assert post[:version] == 1
      assert post[:mode] in ["timestamp", :timestamp]
    end

    test "creates post with title" do
      group = create_group("timestamp")
      {:ok, post} = Posts.create_post(group["slug"], %{title: "My First Post"})
      assert post[:metadata][:title] == "My First Post"
    end

    test "creates post with content" do
      group = create_group("timestamp")
      {:ok, post} = Posts.create_post(group["slug"], %{content: "<p>Hello world</p>"})
      assert post[:content] == "<p>Hello world</p>"
    end

    test "auto-increments time on collision" do
      group = create_group("timestamp")
      {:ok, post1} = Posts.create_post(group["slug"], %{})
      {:ok, post2} = Posts.create_post(group["slug"], %{})
      assert post1[:uuid] != post2[:uuid]
      assert post1[:date] == post2[:date]
    end

    test "status defaults to draft" do
      group = create_group("timestamp")
      {:ok, post} = Posts.create_post(group["slug"], %{})
      assert post[:metadata][:status] == "draft"
    end

    test "creates version 1 and primary language content automatically" do
      group = create_group("timestamp")
      {:ok, post} = Posts.create_post(group["slug"], %{title: "Auto V1"})

      assert post[:version] == 1
      assert post[:language] == "en"
    end
  end

  # ============================================================================
  # create_post/2 — slug mode
  # ============================================================================

  describe "create_post/2 in slug mode" do
    test "creates post with auto-generated slug from title" do
      group = create_group("slug")
      {:ok, post} = Posts.create_post(group["slug"], %{title: "My Slug Post"})
      assert post[:slug]
      assert post[:version] == 1
      assert post[:mode] in ["slug", :slug]
    end

    test "creates post with custom slug" do
      group = create_group("slug")
      {:ok, post} = Posts.create_post(group["slug"], %{slug: "custom-slug"})
      assert post[:slug] == "custom-slug"
    end

    test "creates post without title" do
      group = create_group("slug")
      {:ok, post} = Posts.create_post(group["slug"], %{})
      assert post[:uuid]
      assert post[:slug]
    end

    test "posts in different groups can share slugs" do
      group1 = create_group("slug")
      group2 = create_group("slug")
      {:ok, p1} = Posts.create_post(group1["slug"], %{slug: "shared-slug"})
      {:ok, p2} = Posts.create_post(group2["slug"], %{slug: "shared-slug"})
      assert p1[:uuid] != p2[:uuid]
    end
  end

  # ============================================================================
  # read_post/4
  # ============================================================================

  describe "read_post/4" do
    test "reads post by uuid" do
      group = create_group("timestamp")
      {:ok, created} = Posts.create_post(group["slug"], %{title: "Read Me"})
      {:ok, post} = Posts.read_post(group["slug"], created[:uuid], nil, nil)
      assert post[:uuid] == created[:uuid]
      assert post[:metadata][:title] == "Read Me"
    end

    test "reads timestamp-mode post by date and time" do
      group = create_group("timestamp")
      {:ok, created} = Posts.create_post(group["slug"], %{title: "By DateTime"})

      date = created[:date]
      time = created[:time]
      identifier = "#{date}/#{Time.to_string(time) |> String.slice(0, 5)}"

      {:ok, post} = Posts.read_post(group["slug"], identifier, nil, nil)
      assert post[:uuid] == created[:uuid]
    end

    test "reads timestamp-mode post by date only (single post on date)" do
      group = create_group("timestamp")
      {:ok, created} = Posts.create_post(group["slug"], %{title: "Date Only"})

      date_str = Date.to_iso8601(created[:date])
      {:ok, post} = Posts.read_post(group["slug"], date_str, nil, nil)
      assert post[:uuid] == created[:uuid]
    end

    test "reads post by slug in slug mode" do
      group = create_group("slug")
      {:ok, created} = Posts.create_post(group["slug"], %{slug: "readable-post"})
      {:ok, post} = Posts.read_post(group["slug"], "readable-post", nil, nil)
      assert post[:uuid] == created[:uuid]
    end

    test "returns full post map structure" do
      group = create_group("slug")
      {:ok, created} = Posts.create_post(group["slug"], %{title: "Full Structure"})
      {:ok, post} = Posts.read_post(group["slug"], created[:uuid], nil, nil)

      assert post[:uuid]
      assert post[:version]
      assert post[:language]
      assert post[:metadata]
      assert post[:available_versions]
      assert is_list(post[:available_versions])
    end

    test "reads specific version" do
      group = create_group("slug")
      {:ok, created} = Posts.create_post(group["slug"], %{title: "V1"})
      {:ok, _v2} = Versions.create_new_version(group["slug"], created, %{}, %{})

      {:ok, v1} = Posts.read_post(group["slug"], created[:uuid], nil, 1)
      assert v1[:version] == 1

      {:ok, v2} = Posts.read_post(group["slug"], created[:uuid], nil, 2)
      assert v2[:version] == 2
    end

    test "added language appears in available_languages" do
      group = create_group("slug")
      {:ok, created} = Posts.create_post(group["slug"], %{title: "English"})

      alias PhoenixKit.Modules.Publishing.TranslationManager
      {:ok, _} = TranslationManager.add_language_to_post(group["slug"], created[:uuid], "de", nil)

      {:ok, post} = Posts.read_post(group["slug"], created[:uuid], nil, nil)
      assert "de" in post[:available_languages]
    end

    test "returns error for nonexistent post" do
      group = create_group("timestamp")
      assert {:error, _} = Posts.read_post(group["slug"], "nonexistent", nil, nil)
    end

    test "defaults to latest version when nil" do
      group = create_group("slug")
      {:ok, created} = Posts.create_post(group["slug"], %{title: "V1"})
      {:ok, _v2} = Versions.create_new_version(group["slug"], created, %{}, %{})

      {:ok, post} = Posts.read_post(group["slug"], created[:uuid], nil, nil)
      assert post[:version] == 2
    end
  end

  # ============================================================================
  # update_post/4
  # ============================================================================

  describe "update_post/4" do
    test "updates post title" do
      group = create_group("slug")
      {:ok, post} = Posts.create_post(group["slug"], %{title: "Original"})

      {:ok, updated} =
        Posts.update_post(group["slug"], post, %{"title" => "Updated Title"}, %{})

      assert updated[:metadata][:title] == "Updated Title"
    end

    test "updates post content" do
      group = create_group("slug")
      {:ok, post} = Posts.create_post(group["slug"], %{title: "Has Content"})

      {:ok, updated} =
        Posts.update_post(group["slug"], post, %{"content" => "<p>New body</p>"}, %{})

      assert updated[:content] == "<p>New body</p>"
    end

    test "returns updated post map" do
      group = create_group("slug")
      {:ok, post} = Posts.create_post(group["slug"], %{title: "Check Return"})

      {:ok, updated} =
        Posts.update_post(group["slug"], post, %{"title" => "New"}, %{})

      assert updated[:uuid] == post[:uuid]
      assert updated[:version]
      assert updated[:metadata]
    end
  end

  # ============================================================================
  # list_posts/2
  # ============================================================================

  describe "list_posts/2" do
    test "lists posts in group" do
      group = create_group("timestamp")
      {:ok, _} = Posts.create_post(group["slug"], %{title: "Post 1"})
      {:ok, _} = Posts.create_post(group["slug"], %{title: "Post 2"})
      posts = Posts.list_posts(group["slug"], nil)
      assert length(posts) >= 2
    end

    test "returns empty list for empty group" do
      group = create_group("timestamp")
      assert Posts.list_posts(group["slug"], nil) == []
    end

    test "does not list trashed posts" do
      group = create_group("slug")
      {:ok, post} = Posts.create_post(group["slug"], %{title: "Trashable"})
      {:ok, _} = Posts.trash_post(group["slug"], post[:uuid])

      posts = Posts.list_posts(group["slug"], nil)
      uuids = Enum.map(posts, & &1[:uuid])
      refute post[:uuid] in uuids
    end

    test "does not list posts from other groups" do
      group1 = create_group("slug")
      group2 = create_group("slug")
      {:ok, p1} = Posts.create_post(group1["slug"], %{title: "Group 1"})
      {:ok, _} = Posts.create_post(group2["slug"], %{title: "Group 2"})

      posts = Posts.list_posts(group1["slug"], nil)
      uuids = Enum.map(posts, & &1[:uuid])
      assert p1[:uuid] in uuids
      assert length(posts) == 1
    end
  end

  # ============================================================================
  # list_posts_by_status/2
  # ============================================================================

  describe "list_posts_by_status/2" do
    test "lists only published posts" do
      group = create_group("slug")
      {:ok, draft} = Posts.create_post(group["slug"], %{title: "Draft"})
      {:ok, pub} = Posts.create_post(group["slug"], %{title: "Published"})
      :ok = Versions.publish_version(group["slug"], pub[:uuid], 1)

      published = Posts.list_posts_by_status(group["slug"], "published")
      uuids = Enum.map(published, &(&1[:uuid] || &1.uuid))

      assert pub[:uuid] in uuids
      refute draft[:uuid] in uuids
    end

    test "lists only draft posts" do
      group = create_group("slug")
      {:ok, _} = Posts.create_post(group["slug"], %{title: "Draft"})

      drafts = Posts.list_posts_by_status(group["slug"], "draft")
      assert drafts != []
    end
  end

  # ============================================================================
  # trash_post/2 and restore_post/2
  # ============================================================================

  describe "trash_post/2 and restore_post/2" do
    test "trashes a post" do
      group = create_group("slug")
      {:ok, post} = Posts.create_post(group["slug"], %{title: "Trash Me"})
      assert {:ok, _uuid} = Posts.trash_post(group["slug"], post[:uuid])
    end

    test "trashed post is excluded from list_posts" do
      group = create_group("slug")
      {:ok, post} = Posts.create_post(group["slug"], %{title: "Check Status"})
      {:ok, _} = Posts.trash_post(group["slug"], post[:uuid])

      posts = Posts.list_posts(group["slug"], nil)
      uuids = Enum.map(posts, & &1[:uuid])
      refute post[:uuid] in uuids
    end

    test "restores a trashed post to draft" do
      group = create_group("slug")
      {:ok, post} = Posts.create_post(group["slug"], %{title: "Restore Me"})
      {:ok, _} = Posts.trash_post(group["slug"], post[:uuid])
      assert {:ok, _uuid} = Posts.restore_post(group["slug"], post[:uuid])

      {:ok, restored} = Posts.read_post(group["slug"], post[:uuid], nil, nil)
      status = restored[:status] || restored[:metadata][:status]
      assert status == "draft"
    end

    test "trash nonexistent post returns error" do
      group = create_group("slug")
      assert {:error, _} = Posts.trash_post(group["slug"], UUIDv7.generate())
    end
  end

  # ============================================================================
  # Publishing via Versions.publish_version/3
  # ============================================================================

  describe "publish via Versions.publish_version/3" do
    test "publishes a post with title" do
      group = create_group("slug")
      {:ok, post} = Posts.create_post(group["slug"], %{title: "Publishable"})
      assert :ok = Versions.publish_version(group["slug"], post[:uuid], 1)
    end

    test "unpublishes a published post" do
      group = create_group("slug")
      {:ok, post} = Posts.create_post(group["slug"], %{title: "Unpublish Me"})
      :ok = Versions.publish_version(group["slug"], post[:uuid], 1)
      assert :ok = Versions.unpublish_post(group["slug"], post[:uuid])
    end

    test "publishing post without title returns error" do
      group = create_group("slug")
      {:ok, post} = Posts.create_post(group["slug"], %{})
      assert {:error, :title_required} = Versions.publish_version(group["slug"], post[:uuid], 1)
    end

    test "nonexistent post returns error" do
      group = create_group("slug")
      result = Versions.publish_version(group["slug"], UUIDv7.generate(), 1)
      assert match?({:error, _}, result)
    end
  end

  # ============================================================================
  # Full publish workflow end-to-end
  # ============================================================================

  describe "full publish workflow" do
    test "create → edit → publish → read published" do
      group = create_group("slug")

      # Create
      {:ok, post} = Posts.create_post(group["slug"], %{title: "Draft Post"})
      assert post[:metadata][:status] == "draft"

      # Edit content (title preserved since we pass it explicitly)
      {:ok, edited} =
        Posts.update_post(
          group["slug"],
          post,
          %{"title" => "Draft Post", "content" => "<p>Final content</p>"},
          %{}
        )

      assert edited[:content] == "<p>Final content</p>"

      # Publish via version
      :ok = Versions.publish_version(group["slug"], post[:uuid], 1)

      # Read published — post should have active_version_uuid set
      {:ok, published} = Posts.read_post(group["slug"], post[:uuid], nil, nil)
      assert published[:uuid] == post[:uuid]
      assert published[:metadata][:status] == "published"
    end

    test "create → trash → restore → publish" do
      group = create_group("slug")
      {:ok, post} = Posts.create_post(group["slug"], %{title: "Lifecycle"})

      # Trash
      {:ok, _} = Posts.trash_post(group["slug"], post[:uuid])

      # Restore
      {:ok, _} = Posts.restore_post(group["slug"], post[:uuid])

      # Publish via version
      assert :ok = Versions.publish_version(group["slug"], post[:uuid], 1)
    end
  end

  # ============================================================================
  # V2 schema behavior
  # ============================================================================

  describe "V2 schema behavior" do
    alias PhoenixKit.Modules.Publishing.DBStorage

    test "active_version_uuid is set when version is published" do
      group = create_group("slug")
      {:ok, post} = Posts.create_post(group["slug"], %{title: "Active Version"})
      :ok = Versions.publish_version(group["slug"], post[:uuid], 1)

      db_post = DBStorage.get_post_by_uuid(post[:uuid])
      assert db_post.active_version_uuid != nil
    end

    test "active_version_uuid is cleared when post is unpublished" do
      group = create_group("slug")
      {:ok, post} = Posts.create_post(group["slug"], %{title: "Unpublish Me"})
      :ok = Versions.publish_version(group["slug"], post[:uuid], 1)
      :ok = Versions.unpublish_post(group["slug"], post[:uuid])

      db_post = DBStorage.get_post_by_uuid(post[:uuid])
      assert db_post.active_version_uuid == nil
    end

    test "trashed_at is set when post is trashed" do
      group = create_group("slug")
      {:ok, post} = Posts.create_post(group["slug"], %{title: "Trash Me"})
      {:ok, _} = Posts.trash_post(group["slug"], post[:uuid])

      db_post = DBStorage.get_post_by_uuid(post[:uuid])
      assert db_post.trashed_at != nil
    end

    test "trashed_at is cleared when post is restored" do
      group = create_group("slug")
      {:ok, post} = Posts.create_post(group["slug"], %{title: "Restore Me"})
      {:ok, _} = Posts.trash_post(group["slug"], post[:uuid])
      {:ok, _} = Posts.restore_post(group["slug"], post[:uuid])

      db_post = DBStorage.get_post_by_uuid(post[:uuid])
      assert db_post.trashed_at == nil
    end

    test "trashed posts are excluded from listings" do
      group = create_group("slug")
      {:ok, post1} = Posts.create_post(group["slug"], %{title: "Visible"})
      {:ok, post2} = Posts.create_post(group["slug"], %{title: "Trashed"})
      {:ok, _} = Posts.trash_post(group["slug"], post2[:uuid])

      posts = Posts.list_posts(group["slug"], nil)
      uuids = Enum.map(posts, & &1[:uuid])

      assert post1[:uuid] in uuids
      refute post2[:uuid] in uuids
    end

    test "version published_at is set on first publish" do
      group = create_group("slug")
      {:ok, post} = Posts.create_post(group["slug"], %{title: "Publish Date"})
      :ok = Versions.publish_version(group["slug"], post[:uuid], 1)

      version = DBStorage.get_version(post[:uuid], 1)
      assert version.published_at != nil
    end

    test "changing published_at syncs post_date and post_time for timestamp-mode posts" do
      group = create_group("timestamp")
      {:ok, post} = Posts.create_post(group["slug"], %{title: "Date Sync Test"})

      original_post = DBStorage.get_post_by_uuid(post[:uuid])
      original_date = original_post.post_date
      original_time = original_post.post_time

      # Update with a different published_at
      new_dt = "2025-12-25T18:30:00Z"

      {:ok, _updated} =
        Posts.update_post(group["slug"], post, %{
          "published_at" => new_dt,
          "content" => "test"
        })

      # The post's date/time should now match the new published_at
      db_post = DBStorage.get_post_by_uuid(post[:uuid])
      assert db_post.post_date == ~D[2025-12-25]
      assert db_post.post_time == ~T[18:30:00]
      assert db_post.post_date != original_date or db_post.post_time != original_time
    end

    test "list_posts_for_listing only includes published posts with active version content" do
      group = create_group("slug")

      # Create two posts
      {:ok, published_post} = Posts.create_post(group["slug"], %{title: "Published"})
      {:ok, draft_post} = Posts.create_post(group["slug"], %{title: "Draft Only"})

      # Publish only the first one
      :ok = Versions.publish_version(group["slug"], published_post[:uuid], 1)

      # Create a new draft version on the published post (v2 = draft, v1 = published)
      {:ok, _v2} = Versions.create_new_version(group["slug"], published_post, %{}, %{})

      listing = DBStorage.list_posts_for_listing(group["slug"])

      # Only the published post should appear
      assert length(listing) == 1
      assert hd(listing).uuid == published_post[:uuid]

      # The listing should use the published version (v1), not the draft (v2)
      assert hd(listing).version == 1
      assert hd(listing).metadata.title == "Published"
    end
  end
end
