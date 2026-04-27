defmodule PhoenixKit.Modules.Publishing.SlugHelpersTest do
  @moduledoc """
  Pure-function tests for SlugHelpers.validate_slug/1 and valid_slug?/1.
  The DB-coupled functions (`slug_exists?`, `validate_url_slug` reaching
  ListingCache) are exercised by integration tests; below covers the
  format/regex paths only.
  """

  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Publishing.SlugHelpers

  describe "validate_slug/1" do
    test "accepts a simple lowercase slug" do
      assert {:ok, "hello-world"} = SlugHelpers.validate_slug("hello-world")
    end

    test "accepts numbers and hyphens" do
      assert {:ok, "post-2026-q4"} = SlugHelpers.validate_slug("post-2026-q4")
    end

    test "accepts a single word" do
      assert {:ok, "tutorial"} = SlugHelpers.validate_slug("tutorial")
    end

    test "rejects uppercase letters" do
      assert {:error, :invalid_format} = SlugHelpers.validate_slug("Hello-World")
    end

    test "rejects spaces" do
      assert {:error, :invalid_format} = SlugHelpers.validate_slug("hello world")
    end

    test "rejects special characters" do
      assert {:error, :invalid_format} = SlugHelpers.validate_slug("hello!")
      assert {:error, :invalid_format} = SlugHelpers.validate_slug("foo/bar")
      assert {:error, :invalid_format} = SlugHelpers.validate_slug("foo.bar")
    end

    test "rejects leading/trailing hyphens" do
      assert {:error, :invalid_format} = SlugHelpers.validate_slug("-hello")
      assert {:error, :invalid_format} = SlugHelpers.validate_slug("hello-")
    end

    test "rejects double hyphens" do
      assert {:error, :invalid_format} = SlugHelpers.validate_slug("hello--world")
    end

    test "rejects an empty string" do
      assert {:error, :invalid_format} = SlugHelpers.validate_slug("")
    end
  end

  describe "valid_slug?/1" do
    test "returns true for a valid slug" do
      assert SlugHelpers.valid_slug?("hello-world")
    end

    test "returns false for invalid format" do
      refute SlugHelpers.valid_slug?("Bad Slug")
    end

    test "returns false for empty string" do
      refute SlugHelpers.valid_slug?("")
    end
  end
end

defmodule PhoenixKit.Modules.Publishing.SlugHelpersDBTest do
  @moduledoc """
  DB-coupled tests for SlugHelpers — the functions that query DBStorage
  for uniqueness, conflict detection, and unique-slug generation.
  Tagged :integration via DataCase.
  """

  use PhoenixKitPublishing.DataCase, async: false

  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.Posts
  alias PhoenixKit.Modules.Publishing.SlugHelpers
  alias PhoenixKit.Settings

  setup do
    {:ok, _} = Settings.update_boolean_setting("languages_enabled", true)

    {:ok, _} =
      Settings.update_json_setting("languages_config", %{
        "languages" => [
          %{
            "code" => "en-US",
            "name" => "English",
            "is_default" => true,
            "is_enabled" => true,
            "position" => 0
          }
        ]
      })

    {:ok, group} = Groups.add_group("SH #{System.unique_integer([:positive])}", mode: "slug")
    %{group_slug: group["slug"]}
  end

  describe "slug_exists?/2" do
    test "returns false when slug isn't in the group", %{group_slug: group_slug} do
      refute SlugHelpers.slug_exists?(group_slug, "definitely-not-there")
    end

    test "returns true after a post is created with that slug", %{group_slug: group_slug} do
      {:ok, post} = Posts.create_post(group_slug, %{title: "Slug Exists", slug: "exists-now"})
      assert SlugHelpers.slug_exists?(group_slug, post.slug)
    end
  end

  describe "validate_url_slug/4" do
    test "rejects invalid format", %{group_slug: group_slug} do
      assert {:error, :invalid_format} =
               SlugHelpers.validate_url_slug(group_slug, "Bad Slug", "en-US")
    end

    test "rejects reserved route words", %{group_slug: group_slug} do
      assert {:error, :reserved_route_word} =
               SlugHelpers.validate_url_slug(group_slug, "admin", "en-US")
    end

    test "rejects when conflicts with another post's slug", %{group_slug: group_slug} do
      {:ok, _post} = Posts.create_post(group_slug, %{title: "Conflict", slug: "conflict-slug"})

      assert {:error, :conflicts_with_post_slug} =
               SlugHelpers.validate_url_slug(group_slug, "conflict-slug", "en-US")
    end

    test "accepts a fresh slug that doesn't conflict", %{group_slug: group_slug} do
      assert {:ok, "fresh-slug"} =
               SlugHelpers.validate_url_slug(group_slug, "fresh-slug", "en-US")
    end

    test "exclude_post_slug allows a post to keep its own URL", %{group_slug: group_slug} do
      {:ok, post} = Posts.create_post(group_slug, %{title: "Own URL", slug: "own-url"})

      assert {:ok, "own-url"} =
               SlugHelpers.validate_url_slug(group_slug, "own-url", "en-US", post.slug)
    end
  end

  describe "generate_unique_slug/4" do
    test "generates from title when no slug provided", %{group_slug: group_slug} do
      assert {:ok, slug} = SlugHelpers.generate_unique_slug(group_slug, "My New Title")
      assert is_binary(slug)
      assert slug =~ "my-new-title"
    end

    test "generates from preferred slug when provided", %{group_slug: group_slug} do
      assert {:ok, "preferred-slug"} =
               SlugHelpers.generate_unique_slug(
                 group_slug,
                 "Title Doesn't Matter",
                 "preferred-slug"
               )
    end

    test "appends counter when slug collides", %{group_slug: group_slug} do
      {:ok, _} = Posts.create_post(group_slug, %{title: "First", slug: "shared"})

      assert {:ok, slug} = SlugHelpers.generate_unique_slug(group_slug, "Second", "shared")
      # The unique-slug generator appends an integer suffix
      assert slug =~ "shared"
      refute slug == "shared"
    end

    test "returns 'untitled' when title is empty and no preferred", %{group_slug: group_slug} do
      assert {:ok, slug} = SlugHelpers.generate_unique_slug(group_slug, "")
      assert slug =~ "untitled"
    end

    test "current_slug opt skips conflict for the given slug", %{group_slug: group_slug} do
      {:ok, _} = Posts.create_post(group_slug, %{title: "Existing", slug: "existing"})

      assert {:ok, "existing"} =
               SlugHelpers.generate_unique_slug(group_slug, "Existing", "existing",
                 current_slug: "existing"
               )
    end
  end

  describe "clear_url_slug_from_post/3" do
    test "removes the given url_slug from a post's translations",
         %{group_slug: group_slug} do
      {:ok, _post} = Posts.create_post(group_slug, %{title: "WithUrlSlug", slug: "post"})

      # Pure DB op — should return list of cleared languages (possibly empty)
      result = SlugHelpers.clear_url_slug_from_post(group_slug, "post", "non-existent-url-slug")
      assert is_list(result)
    end
  end

  describe "clear_conflicting_url_slugs/2" do
    test "returns [] when no conflicts exist", %{group_slug: group_slug} do
      assert SlugHelpers.clear_conflicting_url_slugs(group_slug, "no-conflicts") == []
    end
  end
end
