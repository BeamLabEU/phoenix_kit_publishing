defmodule PhoenixKit.Modules.Publishing.Web.Controller.PostRenderingHelpersTest do
  @moduledoc """
  Direct unit tests for the pure helpers exported by `PostRendering`:
  `build_version_url/4`, `build_timestamp_url/4`, `render_post_content/1`.
  Functions that touch DB / Plug.Conn are exercised through
  `public_routes_test.exs`.
  """

  # build_breadcrumbs queries Listing.fetch_group → DB, so use DataCase.
  use PhoenixKitPublishing.DataCase, async: false

  alias PhoenixKit.Modules.Publishing.Web.Controller.PostRendering

  describe "build_version_url/4" do
    test "appends `/v/<version>` to the post URL" do
      post = %{slug: "my-post", mode: :slug, metadata: %{published_at: nil}}
      url = PostRendering.build_version_url("blog", post, "en", 2)
      assert url =~ "/v/2"
    end
  end

  describe "render_post_content/1" do
    test "returns rendered HTML for a draft post (no cache)" do
      post = %{
        content: "# Hello\n\nBody text.",
        metadata: %{title: "Hello", status: "draft"},
        slug: "hello",
        mode: :slug,
        group: "blog"
      }

      html = PostRendering.render_post_content(post)
      assert is_binary(html)
      assert html =~ "Hello"
    end

    test "returns rendered HTML for a published post (cache key path)" do
      post = %{
        content: "## Section",
        metadata: %{title: "Pub", status: "published"},
        slug: "pub",
        uuid: "post-uuid-123",
        language: "en",
        mode: :slug,
        group: "blog"
      }

      html = PostRendering.render_post_content(post)
      assert is_binary(html)
    end

    test "handles empty content gracefully" do
      post = %{
        content: "",
        metadata: %{title: "", status: "draft"},
        slug: "x",
        mode: :slug,
        group: "blog"
      }

      assert "" = PostRendering.render_post_content(post)
    end
  end

  describe "build_timestamp_url/4 + build_breadcrumbs/3" do
    test "build_timestamp_url returns a path string" do
      url = PostRendering.build_timestamp_url("blog", "2026-04-27", "10:00", "en")
      assert is_binary(url)
      assert url =~ "blog"
    end

    test "build_breadcrumbs returns a 2-element list with group + post" do
      post = %{slug: "x", metadata: %{title: "Title"}, mode: :slug}
      result = PostRendering.build_breadcrumbs("nonexistent-group", post, "en")

      assert is_list(result)
      assert length(result) == 2
    end
  end

  describe "handle_date_only_url/4" do
    test "function exists with the right arity" do
      # Full flow is exercised by rich_fixtures_test through the public route.
      assert function_exported?(PostRendering, :handle_date_only_url, 4)
    end
  end
end
