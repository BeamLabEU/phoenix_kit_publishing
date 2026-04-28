defmodule PhoenixKit.Modules.Publishing.Web.Editor.HelpersTest do
  @moduledoc """
  Pure-function tests for editor helpers — URL building, virtual post
  construction, language list formatting, featured-image sanitisation.
  No DB or LV needed.
  """

  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Publishing.Web.Editor.Helpers

  @post_uuid "019cce93-aaaa-7000-8000-000000000001"

  describe "format_language_list/1" do
    test "returns empty string for empty list" do
      assert Helpers.format_language_list([]) == ""
    end

    test "returns single name for one-language list" do
      assert Helpers.format_language_list(["xx"]) == "XX"
    end

    test "joins up to 3 language names with commas" do
      result = Helpers.format_language_list(["aa", "bb"])
      assert result =~ "AA"
      assert result =~ "BB"
      assert result =~ ","
    end

    test "switches to 'N languages' summary for >3 entries" do
      assert Helpers.format_language_list(~w(aa bb cc dd)) == "4 languages"
      assert Helpers.format_language_list(~w(aa bb cc dd ee ff)) == "6 languages"
    end

    test "non-list input returns empty string" do
      assert Helpers.format_language_list("nope") == ""
      assert Helpers.format_language_list(nil) == ""
    end
  end

  describe "get_language_name/1" do
    test "uppercases unknown language code as fallback" do
      assert Helpers.get_language_name("zz") == "ZZ"
    end
  end

  describe "sanitize_featured_image_uuid/1" do
    test "trims whitespace and returns the value" do
      assert Helpers.sanitize_featured_image_uuid("  abc-123  ") == "abc-123"
    end

    test "returns nil for empty / whitespace-only strings" do
      assert Helpers.sanitize_featured_image_uuid("") == nil
      assert Helpers.sanitize_featured_image_uuid("   ") == nil
    end

    test "returns nil for non-binary input" do
      assert Helpers.sanitize_featured_image_uuid(nil) == nil
      assert Helpers.sanitize_featured_image_uuid(123) == nil
      assert Helpers.sanitize_featured_image_uuid(:atom) == nil
    end
  end

  describe "build_virtual_post/4 — slug mode" do
    test "returns a draft post shell with empty slug + content + title" do
      now = ~U[2026-04-27 12:00:00Z]
      post = Helpers.build_virtual_post("blog", "slug", "en", now)

      assert post.group == "blog"
      assert post.mode == :slug
      assert post.slug == nil
      assert post.metadata.title == ""
      assert post.metadata.status == "draft"
      assert post.metadata.slug == ""
      assert post.content == ""
      assert post.language == "en"
      assert post.available_languages == []
      assert post.metadata.featured_image_uuid == nil
    end
  end

  describe "build_virtual_post/4 — timestamp mode" do
    test "returns a draft post with date and time set from `now`" do
      now = ~U[2026-04-27 14:30:00Z]
      post = Helpers.build_virtual_post("blog", "timestamp", "en", now)

      assert post.group == "blog"
      assert post.mode == :timestamp
      assert post.date == ~D[2026-04-27]
      assert post.time == ~T[14:30:00]
      assert post.metadata.title == ""
      assert post.metadata.status == "draft"
      assert post.metadata.featured_image_uuid == nil
    end
  end

  describe "build_post_url/2" do
    test "builds the overview path with the post uuid" do
      assert Helpers.build_post_url("blog", %{uuid: @post_uuid}) =~
               "/admin/publishing/blog/#{@post_uuid}"
    end

    test "raises when post uuid is nil" do
      assert_raise ArgumentError, ~r/post UUID is required/, fn ->
        Helpers.build_post_url("blog", %{uuid: nil})
      end
    end
  end

  describe "build_edit_url/3" do
    test "builds the edit path without query params when no opts" do
      url = Helpers.build_edit_url("blog", %{uuid: @post_uuid})
      assert url =~ "/admin/publishing/blog/#{@post_uuid}/edit"
      refute url =~ "?"
    end

    test "appends ?v=N when :version opt provided" do
      url = Helpers.build_edit_url("blog", %{uuid: @post_uuid}, version: 2)
      assert url =~ "v=2"
    end

    test "appends ?lang=xx when :lang opt provided" do
      url = Helpers.build_edit_url("blog", %{uuid: @post_uuid}, lang: "fr")
      assert url =~ "lang=fr"
    end

    test "combines version + lang into the same query string" do
      url = Helpers.build_edit_url("blog", %{uuid: @post_uuid}, version: 3, lang: "fr")
      assert url =~ "v=3"
      assert url =~ "lang=fr"
    end
  end

  describe "build_preview_url/2" do
    test "builds preview path with the post uuid" do
      assert Helpers.build_preview_url("blog", %{uuid: @post_uuid}) =~
               "/admin/publishing/blog/#{@post_uuid}/preview"
    end
  end

  describe "build_new_post_url/1" do
    test "builds the new-post path under a group" do
      assert Helpers.build_new_post_url("blog") =~ "/admin/publishing/blog/new"
    end
  end

  describe "build_public_url/2" do
    test "returns nil for non-published posts" do
      post = %{metadata: %{status: "draft"}, mode: :slug, slug: "x", group: "blog"}
      assert Helpers.build_public_url(post, "en") == nil
    end

    test "returns nil for slug-mode post without a slug" do
      post = %{metadata: %{status: "published"}, mode: :slug, slug: nil, group: "blog"}
      assert Helpers.build_public_url(post, "en") == nil
    end

    test "returns nil for timestamp-mode post without a published_at" do
      post = %{
        metadata: %{status: "published", published_at: nil},
        mode: :timestamp,
        group: "blog"
      }

      assert Helpers.build_public_url(post, "en") == nil
    end

    test "returns nil for unrecognised mode" do
      post = %{metadata: %{status: "published"}, mode: :unrecognised, group: "blog"}
      assert Helpers.build_public_url(post, "en") == nil
    end
  end
end
