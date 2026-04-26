defmodule PhoenixKit.Integration.Publishing.ActivityLoggingTest do
  @moduledoc """
  Per-action tests for the user-driven CRUD activity log entries the C4
  sweep wired into Posts / Groups / Versions / TranslationManager.

  Each test does the minimum mutation that fires the action, then asserts
  the row exists with the right `actor_uuid`, `resource_uuid`, and the
  PII-safe metadata keys we documented in AGENTS.md. The PR-delta-pinning
  rule (playbook C11) means every threaded `actor_uuid` opt is asserted —
  if a future change drops `actor_uuid: …` from a context call, the
  activity row lands with `actor_uuid=nil` and the assertion fails.
  """

  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.DBStorage
  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.Posts
  alias PhoenixKit.Modules.Publishing.TranslationManager
  alias PhoenixKit.Modules.Publishing.Versions
  alias PhoenixKit.Settings

  @actor_uuid "019cce93-aaaa-7000-8000-000000000123"

  defp unique_name, do: "Activity Log #{System.unique_integer([:positive])}"

  setup do
    {:ok, _} = Settings.update_boolean_setting("languages_enabled", true)

    {:ok, _} =
      Settings.update_json_setting("languages_config", %{
        "languages" => [
          %{
            "code" => "en-US",
            "name" => "English (United States)",
            "is_default" => true,
            "is_enabled" => true,
            "position" => 0
          },
          %{
            "code" => "de-DE",
            "name" => "German (Germany)",
            "is_default" => false,
            "is_enabled" => true,
            "position" => 1
          }
        ]
      })

    :ok
  end

  # ============================================================================
  # Group CRUD
  # ============================================================================

  describe "publishing.group.*" do
    test "create logs publishing.group.created with the actor_uuid threaded through" do
      {:ok, group} = Groups.add_group(unique_name(), mode: "slug", actor_uuid: @actor_uuid)

      assert_activity_logged("publishing.group.created",
        actor_uuid: @actor_uuid,
        metadata_has: %{"slug" => group["slug"], "mode" => "slug"}
      )
    end

    test "update logs publishing.group.updated with previous_slug and new slug" do
      {:ok, group} = Groups.add_group(unique_name(), mode: "slug")

      {:ok, updated} =
        Groups.update_group(
          group["slug"],
          %{name: "Renamed", slug: group["slug"] <> "-v2"},
          actor_uuid: @actor_uuid
        )

      assert_activity_logged("publishing.group.updated",
        actor_uuid: @actor_uuid,
        metadata_has: %{"slug" => updated["slug"], "previous_slug" => group["slug"]}
      )
    end

    test "trash logs publishing.group.trashed" do
      {:ok, group} = Groups.add_group(unique_name(), mode: "slug")

      {:ok, _} = Groups.trash_group(group["slug"], actor_uuid: @actor_uuid)

      assert_activity_logged("publishing.group.trashed",
        actor_uuid: @actor_uuid,
        metadata_has: %{"slug" => group["slug"]}
      )
    end

    test "restore logs publishing.group.restored" do
      {:ok, group} = Groups.add_group(unique_name(), mode: "slug")
      {:ok, _} = Groups.trash_group(group["slug"])

      {:ok, _} = Groups.restore_group(group["slug"], actor_uuid: @actor_uuid)

      assert_activity_logged("publishing.group.restored",
        actor_uuid: @actor_uuid,
        metadata_has: %{"slug" => group["slug"]}
      )
    end

    test "remove logs publishing.group.deleted with force: true (hard delete)" do
      {:ok, group} = Groups.add_group(unique_name(), mode: "slug")

      {:ok, _} = Groups.remove_group(group["slug"], force: true, actor_uuid: @actor_uuid)

      assert_activity_logged("publishing.group.deleted",
        actor_uuid: @actor_uuid,
        metadata_has: %{"slug" => group["slug"]}
      )
    end
  end

  # ============================================================================
  # Post CRUD
  # ============================================================================

  describe "publishing.post.*" do
    setup do
      {:ok, group} = Groups.add_group(unique_name(), mode: "slug")
      %{group_slug: group["slug"]}
    end

    test "create logs publishing.post.created", %{group_slug: group_slug} do
      {:ok, post} =
        Posts.create_post(group_slug, %{title: "Hello", actor_uuid: @actor_uuid})

      assert_activity_logged("publishing.post.created",
        actor_uuid: @actor_uuid,
        resource_uuid: post[:uuid],
        metadata_has: %{"group_slug" => group_slug, "slug" => post[:slug]}
      )
    end

    test "update logs publishing.post.updated", %{group_slug: group_slug} do
      {:ok, post} = Posts.create_post(group_slug, %{title: "Original"})

      {:ok, _} =
        Posts.update_post(
          group_slug,
          post,
          %{"title" => "Updated", "content" => "Body"},
          actor_uuid: @actor_uuid
        )

      assert_activity_logged("publishing.post.updated",
        actor_uuid: @actor_uuid,
        resource_uuid: post[:uuid],
        metadata_has: %{"group_slug" => group_slug}
      )
    end

    test "trash + restore log publishing.post.trashed and publishing.post.restored",
         %{group_slug: group_slug} do
      {:ok, post} = Posts.create_post(group_slug, %{title: "Bye"})

      {:ok, _} = Posts.trash_post(group_slug, post[:uuid], actor_uuid: @actor_uuid)

      assert_activity_logged("publishing.post.trashed",
        actor_uuid: @actor_uuid,
        resource_uuid: post[:uuid],
        metadata_has: %{"group_slug" => group_slug}
      )

      {:ok, _} = Posts.restore_post(group_slug, post[:uuid], actor_uuid: @actor_uuid)

      assert_activity_logged("publishing.post.restored",
        actor_uuid: @actor_uuid,
        resource_uuid: post[:uuid],
        metadata_has: %{"group_slug" => group_slug}
      )
    end
  end

  # ============================================================================
  # Version CRUD
  # ============================================================================

  describe "publishing.version.*" do
    setup do
      {:ok, group} = Groups.add_group(unique_name(), mode: "slug")
      {:ok, post} = Posts.create_post(group["slug"], %{title: "Versioned"})
      {:ok, post_with_body} = Posts.update_post(group["slug"], post, %{"content" => "Body"})

      %{group_slug: group["slug"], post: post_with_body}
    end

    test "create_new_version logs publishing.version.created",
         %{group_slug: group_slug, post: post} do
      {:ok, _new_post} =
        Versions.create_new_version(group_slug, post, %{}, actor_uuid: @actor_uuid)

      assert_activity_logged("publishing.version.created",
        actor_uuid: @actor_uuid,
        metadata_has: %{
          "group_slug" => group_slug,
          "post_uuid" => post[:uuid],
          "version_number" => 2
        }
      )
    end

    test "publish + unpublish log the right actions",
         %{group_slug: group_slug, post: post} do
      :ok =
        Versions.publish_version(group_slug, post[:uuid], post[:version], actor_uuid: @actor_uuid)

      assert_activity_logged("publishing.version.published",
        actor_uuid: @actor_uuid,
        metadata_has: %{
          "group_slug" => group_slug,
          "post_uuid" => post[:uuid],
          "version_number" => post[:version]
        }
      )

      :ok = Versions.unpublish_post(group_slug, post[:uuid], actor_uuid: @actor_uuid)

      assert_activity_logged("publishing.post.unpublished",
        actor_uuid: @actor_uuid,
        resource_uuid: post[:uuid],
        metadata_has: %{"group_slug" => group_slug}
      )
    end

    test "delete_version logs publishing.version.deleted",
         %{group_slug: group_slug, post: post} do
      # Need at least 2 versions to delete one (validate_version_deletable)
      {:ok, _} = Versions.create_new_version(group_slug, post)

      :ok = Versions.delete_version(group_slug, post[:uuid], 1, actor_uuid: @actor_uuid)

      assert_activity_logged("publishing.version.deleted",
        actor_uuid: @actor_uuid,
        metadata_has: %{
          "group_slug" => group_slug,
          "post_uuid" => post[:uuid],
          "version_number" => 1
        }
      )
    end
  end

  # ============================================================================
  # Translation CRUD
  # ============================================================================

  describe "publishing.translation.*" do
    setup do
      {:ok, group} = Groups.add_group(unique_name(), mode: "slug")
      {:ok, post} = Posts.create_post(group["slug"], %{title: "Translatable"})
      version = DBStorage.get_latest_version(post[:uuid])
      %{group_slug: group["slug"], post: post, version: version}
    end

    test "add_language_to_post logs publishing.translation.added",
         %{group_slug: group_slug, post: post} do
      {:ok, _} =
        TranslationManager.add_language_to_post(
          group_slug,
          post[:uuid],
          "de-DE",
          nil,
          actor_uuid: @actor_uuid
        )

      assert_activity_logged("publishing.translation.added",
        actor_uuid: @actor_uuid,
        metadata_has: %{
          "group_slug" => group_slug,
          "post_uuid" => post[:uuid],
          "language" => "de-DE"
        }
      )
    end

    test "delete_language logs publishing.translation.deleted",
         %{group_slug: group_slug, post: post, version: version} do
      {:ok, _} = TranslationManager.add_language_to_post(group_slug, post[:uuid], "de-DE")

      :ok =
        TranslationManager.delete_language(
          group_slug,
          post[:uuid],
          "de-DE",
          nil,
          actor_uuid: @actor_uuid
        )

      assert_activity_logged("publishing.translation.deleted",
        actor_uuid: @actor_uuid,
        metadata_has: %{
          "group_slug" => group_slug,
          "post_uuid" => post[:uuid],
          "language" => "de-DE",
          "version_uuid" => version.uuid
        }
      )
    end
  end

  # ============================================================================
  # Module enable/disable
  # ============================================================================

  describe "publishing.module.*" do
    test "enable_system logs publishing.module.enabled (no actor by design)" do
      {:ok, _} = Publishing.enable_system()

      assert_activity_logged("publishing.module.enabled", actor_uuid: nil)
    end

    test "disable_system logs publishing.module.disabled" do
      {:ok, _} = Publishing.disable_system()

      assert_activity_logged("publishing.module.disabled", actor_uuid: nil)
    end
  end
end
