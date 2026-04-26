defmodule PhoenixKit.Integration.Publishing.LegacyMetadataPromotionTest do
  @moduledoc """
  Pins the PR #2 #7 fix — `preserve_content_data` no longer silently drops
  legacy V1 keys (`description`, `featured_image_uuid`, `seo_title`,
  `excerpt`) on save. They get promoted to `version.data` first, logged
  via `publishing.content.metadata_promoted`, then the content row's
  whitelist (`previous_url_slugs`, `updated_by_uuid`, `custom_css`)
  takes effect.

  These tests would all fail if the migration step were removed.
  """

  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Modules.Publishing.DBStorage
  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.Posts
  alias PhoenixKit.Settings

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
          }
        ]
      })

    {:ok, group} =
      Groups.add_group("Legacy Metadata #{System.unique_integer([:positive])}", mode: "slug")

    {:ok, post} = Posts.create_post(group["slug"], %{title: "Legacy Promotion"})

    %{group_slug: group["slug"], post: post}
  end

  test "legacy keys on content.data are promoted to version.data on save", %{
    group_slug: group_slug,
    post: post
  } do
    [version] = DBStorage.list_versions(post[:uuid])
    [content] = DBStorage.list_contents(version.uuid)

    # Simulate a pre-V88 row by manually putting legacy keys on content.data
    # AND clearing version.data so the promotion path actually fires.
    {:ok, _} =
      DBStorage.update_content(content, %{
        data: %{
          "description" => "Legacy SEO desc",
          "seo_title" => "Legacy SEO title",
          "excerpt" => "Legacy excerpt",
          "featured_image_uuid" => "019cce93-ffff-7000-8000-000000000001",
          "previous_url_slugs" => ["old-slug"]
        }
      })

    {:ok, _} = DBStorage.update_version(version, %{data: %{}})

    # Trigger the save path that runs `collect_legacy_content_promotions/2`.
    {:ok, _updated} =
      Posts.update_post(group_slug, post, %{"title" => post[:metadata][:title], "content" => "x"})

    [post_save_version] = DBStorage.list_versions(post[:uuid])
    [post_save_content] = DBStorage.list_contents(version.uuid)

    # version.data now carries the four V1 keys.
    assert post_save_version.data["description"] == "Legacy SEO desc"
    assert post_save_version.data["seo_title"] == "Legacy SEO title"
    assert post_save_version.data["excerpt"] == "Legacy excerpt"

    assert post_save_version.data["featured_image_uuid"] ==
             "019cce93-ffff-7000-8000-000000000001"

    # content.data has been wiped down to the per-language whitelist —
    # only previous_url_slugs survived. The four V1 keys are gone from here.
    refute Map.has_key?(post_save_content.data, "description")
    refute Map.has_key?(post_save_content.data, "seo_title")
    refute Map.has_key?(post_save_content.data, "excerpt")
    refute Map.has_key?(post_save_content.data, "featured_image_uuid")
    assert post_save_content.data["previous_url_slugs"] == ["old-slug"]

    # Activity row records the promotion.
    assert_activity_logged("publishing.content.metadata_promoted",
      resource_uuid: version.uuid,
      metadata_has: %{
        "language" => "en-US",
        "version_uuid" => version.uuid
      }
    )
  end

  test "no promotion is logged when content.data has no legacy keys", %{
    group_slug: group_slug,
    post: post
  } do
    {:ok, _} = Posts.update_post(group_slug, post, %{"content" => "Body"})

    refute_activity_logged("publishing.content.metadata_promoted")
  end

  test "promotion respects existing version.data (no overwrite)", %{
    group_slug: group_slug,
    post: post
  } do
    [version] = DBStorage.list_versions(post[:uuid])
    [content] = DBStorage.list_contents(version.uuid)

    # Both content and version have a description — promotion must NOT
    # overwrite version's value, because version is the source of truth.
    {:ok, _} =
      DBStorage.update_content(content, %{
        data: %{"description" => "From content (legacy)"}
      })

    {:ok, _} =
      DBStorage.update_version(version, %{data: %{"description" => "From version (current)"}})

    {:ok, _} = Posts.update_post(group_slug, post, %{"content" => "x"})

    [final_version] = DBStorage.list_versions(post[:uuid])
    assert final_version.data["description"] == "From version (current)"

    # No promotion log because no key needed promoting.
    refute_activity_logged("publishing.content.metadata_promoted")
  end

  test "preserve_content_data whitelists the three per-language keys", %{
    group_slug: group_slug,
    post: post
  } do
    [version] = DBStorage.list_versions(post[:uuid])
    [content] = DBStorage.list_contents(version.uuid)

    {:ok, _} =
      DBStorage.update_content(content, %{
        data: %{
          "previous_url_slugs" => ["old-1", "old-2"],
          "updated_by_uuid" => "019cce93-aaaa-7000-8000-000000000999",
          "custom_css" => ".override { color: red; }",
          # noise that should NOT survive
          "garbage_key" => "wipe me"
        }
      })

    {:ok, _} = Posts.update_post(group_slug, post, %{"content" => "x"})

    [post_save_content] = DBStorage.list_contents(version.uuid)

    assert post_save_content.data["previous_url_slugs"] == ["old-1", "old-2"]

    assert post_save_content.data["updated_by_uuid"] ==
             "019cce93-aaaa-7000-8000-000000000999"

    assert post_save_content.data["custom_css"] == ".override { color: red; }"
    refute Map.has_key?(post_save_content.data, "garbage_key")
  end
end
