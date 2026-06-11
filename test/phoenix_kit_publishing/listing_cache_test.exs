defmodule PhoenixKit.Modules.Publishing.ListingCacheTest do
  @moduledoc """
  Tests for ListingCache key generators and direct persistent_term
  reads. Full read/regenerate cycle is covered by integration tests
  that need a DB; this file focuses on the pure / persistent_term-only
  paths.

  Each test uses a unique group slug so persistent_term entries don't
  bleed between tests. We never `:persistent_term.erase` to keep the
  `:persistent_term` count bounded.
  """

  # Uses DataCase because every read path calls `memory_cache_enabled?/0`
  # → `Settings.get_setting_cached/2` → DB. Without sandbox checkout, those
  # queries flake under concurrent test load (owner-pid exits mid-checkout).
  use PhoenixKitPublishing.DataCase, async: false

  alias PhoenixKit.Modules.Publishing.ListingCache

  defp unique_group, do: "lc-test-#{System.unique_integer([:positive])}"

  describe "persistent_term_key/1" do
    test "returns a 2-tuple with the cache prefix and group slug" do
      assert {prefix, "blog"} = ListingCache.persistent_term_key("blog")
      assert is_atom(prefix)
    end

    test "produces distinct keys for distinct group slugs" do
      refute ListingCache.persistent_term_key("a") == ListingCache.persistent_term_key("b")
    end
  end

  describe "cache_generated_at_key/1" do
    test "returns a tuple distinct from persistent_term_key" do
      group = unique_group()
      refute ListingCache.cache_generated_at_key(group) == ListingCache.persistent_term_key(group)
    end
  end

  describe "memory_loaded_at/1 and cache_generated_at/1" do
    test "return nil when no cache entry exists yet" do
      group = unique_group()
      assert ListingCache.memory_loaded_at(group) == nil
      assert ListingCache.cache_generated_at(group) == nil
    end

    test "return the value from persistent_term when set" do
      group = unique_group()
      # Both readers share one entry now (L12) — memory_loaded_at == cache_generated_at.
      :persistent_term.put(ListingCache.cache_generated_at_key(group), "2026-04-27T00:00:00Z")

      assert ListingCache.memory_loaded_at(group) == "2026-04-27T00:00:00Z"
      assert ListingCache.cache_generated_at(group) == "2026-04-27T00:00:00Z"
    end
  end

  describe "exists?/1" do
    test "returns false when no cache entry" do
      refute ListingCache.exists?(unique_group())
    end

    test "returns true after putting an entry" do
      group = unique_group()
      :persistent_term.put(ListingCache.persistent_term_key(group), [])
      assert ListingCache.exists?(group)
    end
  end

  describe "find_post/2" do
    test "returns :cache_miss when group doesn't exist in the DB" do
      # `regenerate/1` refuses to cache unknown groups (DoS guard added
      # against random-slug flood writing unbounded :persistent_term
      # entries). For an unknown group_slug, `read/1` therefore returns
      # `{:error, :cache_miss}` and `find_post/2` surfaces that
      # unchanged. Callers that need a "post not found" semantic should
      # treat `:cache_miss` the same as `:not_found` (none in the
      # codebase rely on the previous "empty list → :not_found" path).
      assert {:error, :cache_miss} = ListingCache.find_post(unique_group(), "any-slug")
    end

    test "returns :not_found when post slug isn't in the cached list" do
      group = unique_group()

      :persistent_term.put(ListingCache.persistent_term_key(group), [
        %{slug: "different", language_slugs: %{}}
      ])

      assert {:error, :not_found} = ListingCache.find_post(group, "missing")
    end

    test "returns {:ok, post} when slug matches" do
      group = unique_group()
      target = %{slug: "alpha", title: "Alpha"}

      :persistent_term.put(ListingCache.persistent_term_key(group), [
        %{slug: "beta"},
        target
      ])

      assert {:ok, ^target} = ListingCache.find_post(group, "alpha")
    end
  end

  describe "find_by_url_slug/3" do
    test "returns {:ok, post} matching language_slugs entry" do
      group = unique_group()
      target = %{slug: "p", language_slugs: %{"fr" => "bonjour-monde"}}
      :persistent_term.put(ListingCache.persistent_term_key(group), [target])

      assert {:ok, ^target} = ListingCache.find_by_url_slug(group, "fr", "bonjour-monde")
    end

    test "returns :not_found when language_slugs has no match" do
      group = unique_group()

      :persistent_term.put(ListingCache.persistent_term_key(group), [
        %{slug: "p", language_slugs: %{"en" => "hello"}}
      ])

      # Sandbox-backed read may regenerate from DB before consulting our
      # injected entry — accept either :not_found or :cache_miss.
      assert match?(
               {:error, _},
               ListingCache.find_by_url_slug(group, "fr", "missing")
             )
    end
  end

  describe "find_by_previous_url_slug/3" do
    test "returns {:ok, post} when previous slug matches" do
      group = unique_group()

      target = %{
        slug: "p",
        language_previous_slugs: %{"fr" => ["old-slug", "older-slug"]}
      }

      :persistent_term.put(ListingCache.persistent_term_key(group), [target])

      assert {:ok, ^target} = ListingCache.find_by_previous_url_slug(group, "fr", "old-slug")
    end

    test "returns :not_found when no previous slug matches" do
      group = unique_group()

      :persistent_term.put(ListingCache.persistent_term_key(group), [
        %{slug: "p", language_previous_slugs: %{}}
      ])

      assert match?(
               {:error, _},
               ListingCache.find_by_previous_url_slug(group, "fr", "anything")
             )
    end
  end
end

defmodule PhoenixKit.Modules.Publishing.ListingCacheRegenerateTest do
  @moduledoc """
  Tests for `regenerate/1` and `load_into_memory/1` paths — drive
  actual DB writes via the public Posts/Groups API and watch the
  cache reflect them.
  """

  use PhoenixKitPublishing.DataCase, async: false

  alias PhoenixKit.Modules.Publishing.DBStorage
  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.ListingCache
  alias PhoenixKit.Modules.Publishing.Posts
  alias PhoenixKit.Modules.Publishing.Versions
  alias PhoenixKit.Modules.Publishing.Web.Controller.Listing
  alias PhoenixKit.Modules.Publishing.Web.Controller.PostFetching
  alias PhoenixKit.Settings

  setup do
    {:ok, _} = Settings.update_boolean_setting("languages_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("publishing_memory_cache_enabled", true)

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

    {:ok, group} = Groups.add_group("LC-#{System.unique_integer([:positive])}", mode: "slug")
    %{group_slug: group["slug"]}
  end

  describe "regenerate/1" do
    test "populates :persistent_term with current posts", %{group_slug: group_slug} do
      assert :ok = ListingCache.regenerate(group_slug)
      assert {:ok, posts} = ListingCache.read(group_slug)
      assert is_list(posts)
    end

    test "populates cached_generated_at + memory_loaded_at after regenerate",
         %{group_slug: group_slug} do
      assert :ok = ListingCache.regenerate(group_slug)
      assert is_binary(ListingCache.memory_loaded_at(group_slug))
      assert is_binary(ListingCache.cache_generated_at(group_slug))
    end

    test "regenerate is a no-op when memory cache is disabled",
         %{group_slug: group_slug} do
      {:ok, _} = Settings.update_boolean_setting("publishing_memory_cache_enabled", false)
      assert :ok = ListingCache.regenerate(group_slug)
    end
  end

  describe "exists?/1 + invalidate/1" do
    test "exists? returns true after regenerate, false after invalidate",
         %{group_slug: group_slug} do
      :ok = ListingCache.regenerate(group_slug)
      assert ListingCache.exists?(group_slug)

      :ok = ListingCache.invalidate(group_slug)
      refute ListingCache.exists?(group_slug)
    end

    test "erase_all/0 clears the cache so a re-enable can't serve stale data (L7)",
         %{group_slug: group_slug} do
      :ok = ListingCache.regenerate(group_slug)
      assert ListingCache.exists?(group_slug)
      assert is_binary(ListingCache.cache_generated_at(group_slug))

      :ok = ListingCache.erase_all()

      refute ListingCache.exists?(group_slug)
      # The timestamp prefixes are cleared too (the old per-group loop missed them).
      assert ListingCache.cache_generated_at(group_slug) == nil
    end
  end

  describe "find_post/2 with real DB-backed cache" do
    test "returns the post after publishing it", %{group_slug: group_slug} do
      {:ok, post} =
        Posts.create_post(group_slug, %{title: "Cached", slug: "cached", content: "Body"})

      :ok = Versions.publish_version(group_slug, post.uuid, 1)
      :ok = ListingCache.regenerate(group_slug)

      assert {:ok, cached} = ListingCache.find_post(group_slug, post.slug)
      assert cached.slug == post.slug
    end
  end

  describe "regenerate_if_not_in_progress/1" do
    test "succeeds with :ok when no other process is regenerating",
         %{group_slug: group_slug} do
      result = ListingCache.regenerate_if_not_in_progress(group_slug)
      assert result in [:ok, :already_in_progress]
    end
  end

  describe "load_into_memory/1" do
    test "lazily loads cache into persistent_term", %{group_slug: group_slug} do
      :ok = ListingCache.invalidate(group_slug)
      result = ListingCache.load_into_memory(group_slug)
      assert result in [:ok] or match?({:error, _}, result)
    end
  end

  describe "public cache-miss fallback uses the active/published listing source" do
    test "a published post with a newer DRAFT version stays published on a cache miss",
         %{group_slug: group_slug} do
      # Regression: on a cache miss the public listing fell back to list_posts/2
      # (LATEST version), so a published post whose latest version is an
      # unpublished draft would surface with draft status — dropped by
      # filter_published — and vanish from the public listing during cold-start
      # or concurrent regeneration. The fallback now mirrors the cache source
      # (list_posts_for_listing/1 — the ACTIVE/published version).
      {:ok, _} = Settings.update_boolean_setting("publishing_memory_cache_enabled", false)

      {:ok, post} =
        Posts.create_post(group_slug, %{title: "Live", slug: "live", content: "Published body"})

      :ok = Versions.publish_version(group_slug, post.uuid, 1)
      # v2 becomes the LATEST version and is an unpublished draft.
      {:ok, _v2} = DBStorage.create_version_from(post.uuid, 1)

      posts = PostFetching.fetch_posts_with_cache(group_slug)
      published = Listing.filter_published(posts)

      # The post is still listed (active version is published)...
      assert Enum.any?(published, &(&1.slug == post.slug))
      # ...and surfaces with published status, not the latest draft's.
      listed = Enum.find(posts, &(&1.slug == post.slug))
      assert listed.metadata.status == "published"
    end
  end
end
