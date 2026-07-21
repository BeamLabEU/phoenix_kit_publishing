defmodule PhoenixKit.Modules.Publishing.SchemaTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Publishing.PublishingContent
  alias PhoenixKit.Modules.Publishing.PublishingGroup
  alias PhoenixKit.Modules.Publishing.PublishingPost
  alias PhoenixKit.Modules.Publishing.PublishingVersion

  # ============================================================================
  # PublishingGroup
  # ============================================================================

  describe "PublishingGroup" do
    test "module is defined and loadable" do
      assert Code.ensure_loaded?(PublishingGroup)
    end

    test "changeset validates required fields" do
      changeset = PublishingGroup.changeset(%PublishingGroup{}, %{})
      refute changeset.valid?

      assert "can't be blank" in errors_on(changeset, :name)
      # mode has default "timestamp", so it won't be blank
    end

    test "changeset validates mode inclusion" do
      changeset =
        PublishingGroup.changeset(%PublishingGroup{}, %{
          name: "Test",
          slug: "test",
          mode: "invalid"
        })

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset, :mode)
    end

    test "changeset accepts valid modes" do
      for mode <- ["timestamp", "slug"] do
        changeset =
          PublishingGroup.changeset(%PublishingGroup{}, %{
            name: "Test",
            slug: "test",
            mode: mode
          })

        assert changeset.valid?, "Expected mode '#{mode}' to be valid"
      end
    end

    test "changeset auto-generates slug from name when slug provided" do
      changeset =
        PublishingGroup.changeset(%PublishingGroup{}, %{
          name: "My Blog Group",
          slug: "my-blog-group",
          mode: "slug"
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :slug) == "my-blog-group"
    end

    test "data JSONB accessors return defaults" do
      group = %PublishingGroup{data: %{}}

      assert PublishingGroup.get_type(group) == "blog"
      assert PublishingGroup.get_item_singular(group) == "Post"
      assert PublishingGroup.get_item_plural(group) == "Posts"
      assert PublishingGroup.get_description(group) == nil
      assert PublishingGroup.get_icon(group) == nil
      assert PublishingGroup.comments_enabled?(group) == false
      assert PublishingGroup.likes_enabled?(group) == false
      assert PublishingGroup.views_enabled?(group) == false
    end

    test "data JSONB accessors return custom values" do
      group = %PublishingGroup{
        data: %{
          "type" => "faq",
          "item_singular" => "Question",
          "item_plural" => "Questions",
          "description" => "FAQ section",
          "icon" => "hero-question-mark-circle",
          "comments_enabled" => true,
          "likes_enabled" => true,
          "views_enabled" => true
        }
      }

      assert PublishingGroup.get_type(group) == "faq"
      assert PublishingGroup.get_item_singular(group) == "Question"
      assert PublishingGroup.get_item_plural(group) == "Questions"
      assert PublishingGroup.get_description(group) == "FAQ section"
      assert PublishingGroup.get_icon(group) == "hero-question-mark-circle"
      assert PublishingGroup.comments_enabled?(group) == true
      assert PublishingGroup.likes_enabled?(group) == true
      assert PublishingGroup.views_enabled?(group) == true
    end

    test "public-side display accessors return defaults" do
      group = %PublishingGroup{data: %{}}

      assert PublishingGroup.featured_enabled?(group) == true
      assert PublishingGroup.featured_layout(group) == "hero"
      assert PublishingGroup.newest_enabled?(group) == false
      assert PublishingGroup.newest_layout(group) == "hero"
      assert PublishingGroup.featured_style(group) == "classic"
      assert PublishingGroup.newest_style(group) == "classic"
      assert PublishingGroup.scrollbar_style(group) == "default"
      assert PublishingGroup.scroll_progress_enabled?(group) == false
      assert PublishingGroup.scroll_headings_enabled?(group) == false
      assert PublishingGroup.scroll_timeline_enabled?(group) == false
      assert PublishingGroup.scroll_timeline_granularity(group) == "auto"
      assert PublishingGroup.listing_sort(group) == "newest"
      assert PublishingGroup.show_breadcrumbs?(group) == false
      assert PublishingGroup.post_date_position(group) == "below"
      assert PublishingGroup.post_width(group) == "normal"
      assert PublishingGroup.show_featured_image?(group) == false
      assert PublishingGroup.show_reading_time?(group) == false
      assert PublishingGroup.show_tags?(group) == false
      assert PublishingGroup.show_post_count?(group) == false
      assert PublishingGroup.show_top_back_link?(group) == true
      assert PublishingGroup.listing_image_links?(group) == true
      assert PublishingGroup.listing_animations?(group) == true
    end

    test "public-side display accessors return custom values" do
      group = %PublishingGroup{
        data: %{
          "featured_enabled" => false,
          "featured_layout" => "card",
          "newest_enabled" => true,
          "newest_layout" => "card",
          "featured_style" => "cover",
          "newest_style" => "minimal",
          "scrollbar_style" => "branded",
          "scroll_progress_enabled" => true,
          "scroll_headings_enabled" => true,
          "scroll_timeline_enabled" => true,
          "scroll_timeline_granularity" => "month",
          "listing_sort" => "oldest",
          "show_breadcrumbs" => true,
          "post_date_position" => "above",
          "post_width" => "wide",
          "show_featured_image" => true,
          "show_reading_time" => true,
          "show_tags" => true,
          "show_post_count" => true,
          "show_top_back_link" => false,
          "listing_image_links" => false,
          "listing_animations" => false
        }
      }

      assert PublishingGroup.featured_enabled?(group) == false
      assert PublishingGroup.featured_layout(group) == "card"
      assert PublishingGroup.newest_enabled?(group) == true
      assert PublishingGroup.newest_layout(group) == "card"
      assert PublishingGroup.featured_style(group) == "cover"
      assert PublishingGroup.newest_style(group) == "minimal"
      assert PublishingGroup.scrollbar_style(group) == "branded"
      assert PublishingGroup.scroll_progress_enabled?(group) == true
      assert PublishingGroup.scroll_headings_enabled?(group) == true
      assert PublishingGroup.scroll_timeline_enabled?(group) == true
      assert PublishingGroup.scroll_timeline_granularity(group) == "month"
      assert PublishingGroup.listing_sort(group) == "oldest"
      assert PublishingGroup.show_breadcrumbs?(group) == true
      assert PublishingGroup.post_date_position(group) == "above"
      assert PublishingGroup.post_width(group) == "wide"
      assert PublishingGroup.show_featured_image?(group) == true
      assert PublishingGroup.show_reading_time?(group) == true
      assert PublishingGroup.show_tags?(group) == true
      assert PublishingGroup.show_post_count?(group) == true
      assert PublishingGroup.show_top_back_link?(group) == false
      assert PublishingGroup.listing_image_links?(group) == false
      assert PublishingGroup.listing_animations?(group) == false
    end

    test "translated_name/2 falls back to the primary name with no override" do
      group = %PublishingGroup{name: "Blog", data: %{}}
      assert PublishingGroup.translated_name(group, "fr") == "Blog"
      assert PublishingGroup.translated_name(group, "en") == "Blog"
    end

    test "translated_name/2 returns a per-language override, base-tolerant" do
      group = %PublishingGroup{name: "Blog", data: %{"name_i18n" => %{"fr-FR" => "Blogue"}}}

      # exact full-code match, and short-code lookup (how the public side asks)
      assert PublishingGroup.translated_name(group, "fr-FR") == "Blogue"
      assert PublishingGroup.translated_name(group, "fr") == "Blogue"
      # an unrelated language still falls back to the primary name
      assert PublishingGroup.translated_name(group, "de") == "Blog"
    end

    test "translated_name/2 resolves when stored short but asked full" do
      group = %PublishingGroup{name: "Blog", data: %{"name_i18n" => %{"fr" => "Blogue"}}}
      assert PublishingGroup.translated_name(group, "fr-FR") == "Blogue"
    end

    test "translated_name/2 ignores blank overrides" do
      group = %PublishingGroup{name: "Blog", data: %{"name_i18n" => %{"fr" => ""}}}
      assert PublishingGroup.translated_name(group, "fr") == "Blog"
    end
  end

  # ============================================================================
  # PublishingPost
  # ============================================================================

  describe "PublishingPost" do
    test "module is defined and loadable" do
      assert Code.ensure_loaded?(PublishingPost)
    end

    test "changeset validates required fields" do
      changeset = PublishingPost.changeset(%PublishingPost{}, %{})
      refute changeset.valid?

      assert "can't be blank" in errors_on(changeset, :group_uuid)
      # mode has schema default so it won't be blank
    end

    test "changeset requires slug for slug-mode posts" do
      changeset =
        PublishingPost.changeset(%PublishingPost{}, %{
          group_uuid: UUIDv7.generate(),
          mode: "slug"
        })

      assert "can't be blank" in errors_on(changeset, :slug)
    end

    test "changeset requires post_date and post_time for timestamp-mode posts" do
      changeset =
        PublishingPost.changeset(%PublishingPost{}, %{
          group_uuid: UUIDv7.generate(),
          mode: "timestamp"
        })

      assert "can't be blank" in errors_on(changeset, :post_date)
      assert "can't be blank" in errors_on(changeset, :post_time)
      assert errors_on(changeset, :slug) == []
    end

    test "changeset does not validate status (V2 — status derived from active_version_uuid)" do
      # In V2, status is not cast/validated in the changeset.
      # Passing status: "invalid" should not cause a validation error.
      changeset =
        PublishingPost.changeset(%PublishingPost{}, %{
          group_uuid: UUIDv7.generate(),
          slug: "test",
          mode: "slug"
        })

      assert changeset.valid?
      assert errors_on(changeset, :status) == []
    end

    test "status helpers use active_version_uuid and trashed_at" do
      version_uuid = UUIDv7.generate()
      published = %PublishingPost{active_version_uuid: version_uuid, trashed_at: nil}
      draft = %PublishingPost{active_version_uuid: nil, trashed_at: nil}
      trashed = %PublishingPost{active_version_uuid: nil, trashed_at: ~U[2025-06-15 14:30:00Z]}

      assert PublishingPost.published?(published)
      refute PublishingPost.published?(draft)

      assert PublishingPost.draft?(draft)
      refute PublishingPost.draft?(published)
      refute PublishingPost.draft?(trashed)

      assert PublishingPost.trashed?(trashed)
      refute PublishingPost.trashed?(draft)
      refute PublishingPost.trashed?(published)
    end
  end

  # ============================================================================
  # PublishingVersion
  # ============================================================================

  describe "PublishingVersion" do
    test "module is defined and loadable" do
      assert Code.ensure_loaded?(PublishingVersion)
    end

    test "changeset validates required fields" do
      changeset = PublishingVersion.changeset(%PublishingVersion{}, %{})
      refute changeset.valid?

      assert "can't be blank" in errors_on(changeset, :post_uuid)
      assert "can't be blank" in errors_on(changeset, :version_number)
      # status has default "draft"
    end

    test "changeset validates status inclusion" do
      changeset =
        PublishingVersion.changeset(%PublishingVersion{}, %{
          post_uuid: UUIDv7.generate(),
          version_number: 1,
          status: "invalid"
        })

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset, :status)
    end

    test "changeset validates version_number > 0" do
      changeset =
        PublishingVersion.changeset(%PublishingVersion{}, %{
          post_uuid: UUIDv7.generate(),
          version_number: 0,
          status: "draft"
        })

      refute changeset.valid?
      assert "must be greater than 0" in errors_on(changeset, :version_number)
    end

    test "data JSONB accessors" do
      version = %PublishingVersion{data: %{"created_from" => 1, "notes" => "Bug fix"}}

      assert PublishingVersion.get_created_from(version) == 1
      assert PublishingVersion.get_notes(version) == "Bug fix"
    end

    test "data JSONB accessors return nil for empty data" do
      version = %PublishingVersion{data: %{}}

      assert PublishingVersion.get_created_from(version) == nil
      assert PublishingVersion.get_notes(version) == nil
    end

    test "V2 data JSONB accessors return defaults" do
      version = %PublishingVersion{data: %{}}

      assert PublishingVersion.get_allow_version_access(version) == false
      assert PublishingVersion.get_featured_image_uuid(version) == nil
      assert PublishingVersion.get_tags(version) == []
      assert PublishingVersion.get_description(version) == nil
    end

    test "V2 data JSONB accessors return custom values" do
      version = %PublishingVersion{
        data: %{
          "allow_version_access" => true,
          "featured_image_uuid" => "img-uuid-123",
          "tags" => ["elixir", "phoenix"],
          "description" => "A test description"
        }
      }

      assert PublishingVersion.get_allow_version_access(version) == true
      assert PublishingVersion.get_featured_image_uuid(version) == "img-uuid-123"
      assert PublishingVersion.get_tags(version) == ["elixir", "phoenix"]
      assert PublishingVersion.get_description(version) == "A test description"
    end
  end

  # ============================================================================
  # PublishingContent
  # ============================================================================

  describe "PublishingContent" do
    test "module is defined and loadable" do
      assert Code.ensure_loaded?(PublishingContent)
    end

    test "changeset validates required fields" do
      changeset = PublishingContent.changeset(%PublishingContent{}, %{})
      refute changeset.valid?

      assert "can't be blank" in errors_on(changeset, :version_uuid)
      assert "can't be blank" in errors_on(changeset, :language)
      # title defaults to "" via default_if_nil, so it's not required
      # status has default "draft"
    end

    test "changeset validates status inclusion" do
      changeset =
        PublishingContent.changeset(%PublishingContent{}, %{
          version_uuid: UUIDv7.generate(),
          language: "en",
          title: "Test",
          status: "invalid"
        })

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset, :status)
    end

    test "changeset accepts valid content" do
      changeset =
        PublishingContent.changeset(%PublishingContent{}, %{
          version_uuid: UUIDv7.generate(),
          language: "en",
          title: "Test Post",
          status: "draft",
          content: "Hello world",
          url_slug: "custom-url"
        })

      assert changeset.valid?
    end

    test "data JSONB accessors return defaults" do
      content = %PublishingContent{data: %{}}

      assert PublishingContent.get_description(content) == nil
      assert PublishingContent.get_previous_url_slugs(content) == []
      assert PublishingContent.get_featured_image_uuid(content) == nil
      assert PublishingContent.get_seo_title(content) == nil
      assert PublishingContent.get_excerpt(content) == nil
      assert PublishingContent.get_updated_by_uuid(content) == nil
    end

    test "data JSONB accessors return custom values" do
      content = %PublishingContent{
        data: %{
          "description" => "A test post",
          "previous_url_slugs" => ["old-slug"],
          "featured_image_uuid" => "img-456",
          "seo_title" => "SEO Title",
          "excerpt" => "Custom excerpt",
          "updated_by_uuid" => "uuid-789"
        }
      }

      assert PublishingContent.get_description(content) == "A test post"
      assert PublishingContent.get_previous_url_slugs(content) == ["old-slug"]
      assert PublishingContent.get_featured_image_uuid(content) == "img-456"
      assert PublishingContent.get_seo_title(content) == "SEO Title"
      assert PublishingContent.get_excerpt(content) == "Custom excerpt"
      assert PublishingContent.get_updated_by_uuid(content) == "uuid-789"
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp errors_on(changeset, field) do
    changeset.errors
    |> Keyword.get_values(field)
    |> Enum.map(fn {msg, opts} ->
      Regex.replace(~r/%{(\w+)}/, msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
