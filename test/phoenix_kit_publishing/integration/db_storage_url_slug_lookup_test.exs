defmodule PhoenixKit.Integration.Publishing.DBStorageUrlSlugLookupTest do
  @moduledoc """
  Integration tests for the URL-slug lookup queries in `DBStorage`:

    * `find_by_url_slug/3` (custom slug → post slug fallback)
    * `find_by_previous_url_slug/3` (JSONB previous-slug match for 301 redirects)

  The original failure mode that motivated this file: posts that
  accumulated many versions sharing identical content fields crashed
  `repo().one()` with `Ecto.MultipleResultsError`. The test corpus
  before this file only ever exercised single-version posts, so the
  multi-version data shape was a fixture-coverage gap.

  Async: false because the `content_language` setting is a shared
  ETS-cached singleton, mirroring `stale_fixer_test.exs`.
  """

  use PhoenixKit.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.Modules.Publishing.DBStorage
  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.Posts
  alias PhoenixKit.Modules.Publishing.Versions
  alias PhoenixKit.Settings

  defp unique_name, do: "url-lookup-group-#{System.unique_integer([:positive])}"

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

    {:ok, _} = Settings.update_setting("content_language", "en-US")
    :ok
  end

  # ============================================================================
  # find_by_url_slug — happy path + edge cases
  # ============================================================================

  describe "find_by_url_slug/3" do
    test "finds a published single-version post by its custom URL slug" do
      {:ok, group} = Groups.add_group(unique_name(), mode: "slug")

      {:ok, post} =
        Posts.create_post(group["slug"], %{title: "Custom Slug Post", slug: "custom-slug-post"})

      [version] = DBStorage.list_versions(post.uuid)
      [content] = DBStorage.list_contents(version.uuid)
      {:ok, _} = DBStorage.update_content(content, %{url_slug: "shiny-public-slug"})

      :ok = Versions.publish_version(group["slug"], post.uuid, version.version_number)

      found = DBStorage.find_by_url_slug(group["slug"], "en-US", "shiny-public-slug")
      assert found != nil
      assert found.url_slug == "shiny-public-slug"
      assert found.version.post.slug == "custom-slug-post"
    end

    test "falls back to post-slug match when content's url_slug is empty" do
      {:ok, group} = Groups.add_group(unique_name(), mode: "slug")

      {:ok, post} =
        Posts.create_post(group["slug"], %{title: "Slug Fallback", slug: "slug-fallback"})

      [version] = DBStorage.list_versions(post.uuid)
      :ok = Versions.publish_version(group["slug"], post.uuid, version.version_number)

      # No url_slug on the content row — lookup should resolve via the post slug.
      found = DBStorage.find_by_url_slug(group["slug"], "en-US", "slug-fallback")
      assert found != nil
      assert found.version.post.slug == "slug-fallback"
    end

    test "trashed posts do not resolve" do
      {:ok, group} = Groups.add_group(unique_name(), mode: "slug")

      {:ok, post} =
        Posts.create_post(group["slug"], %{title: "Will Be Trashed", slug: "will-be-trashed"})

      [version] = DBStorage.list_versions(post.uuid)
      :ok = Versions.publish_version(group["slug"], post.uuid, version.version_number)

      {:ok, _} = Posts.trash_post(group["slug"], post.uuid)

      assert DBStorage.find_by_url_slug(group["slug"], "en-US", "will-be-trashed") == nil
    end

    test "returns nil for a different language than what's stored" do
      {:ok, group} = Groups.add_group(unique_name(), mode: "slug")

      {:ok, post} =
        Posts.create_post(group["slug"], %{title: "English Only", slug: "english-only"})

      [version] = DBStorage.list_versions(post.uuid)
      :ok = Versions.publish_version(group["slug"], post.uuid, version.version_number)

      # No de-DE content row — should NOT find anything.
      assert DBStorage.find_by_url_slug(group["slug"], "de-DE", "english-only") == nil
    end

    test "returns nil for a different group than what's stored" do
      {:ok, group_a} = Groups.add_group(unique_name(), mode: "slug")
      {:ok, group_b} = Groups.add_group(unique_name(), mode: "slug")

      {:ok, post} =
        Posts.create_post(group_a["slug"], %{title: "Group A Post", slug: "group-a-post"})

      [version] = DBStorage.list_versions(post.uuid)
      :ok = Versions.publish_version(group_a["slug"], post.uuid, version.version_number)

      assert DBStorage.find_by_url_slug(group_b["slug"], "en-US", "group-a-post") == nil
    end

    test "returns nil when nothing matches the slug at all" do
      {:ok, group} = Groups.add_group(unique_name(), mode: "slug")

      assert DBStorage.find_by_url_slug(group["slug"], "en-US", "never-existed") == nil
    end
  end

  # ============================================================================
  # Multi-version regression — the bug that motivated this file
  # ============================================================================

  describe "find_by_url_slug/3 — multi-version regression" do
    test "post with 14 versions sharing an empty url_slug resolves to a single row" do
      # This is the data shape that crashed Hello! in production. Fourteen
      # consecutive version rows, all with `language = en-US` and `url_slug = ""`.
      # Pre-fix the join returned 14 hits → `repo().one()` → MultipleResultsError.
      {:ok, group} = Groups.add_group(unique_name(), mode: "slug")

      {:ok, post} =
        Posts.create_post(group["slug"], %{title: "Hello Multi", slug: "hello-multi"})

      # Create 13 more versions on top of the auto-generated v1.
      for n <- 2..14 do
        {:ok, version} =
          DBStorage.create_version(%{
            post_uuid: post.uuid,
            version_number: n,
            status: "draft"
          })

        {:ok, _} =
          DBStorage.create_content(%{
            version_uuid: version.uuid,
            language: "en-US",
            title: "Hello Multi v#{n}",
            content: "v#{n} body",
            status: "draft",
            url_slug: ""
          })
      end

      # Publish the latest version so the lookup has a clear target.
      :ok = Versions.publish_version(group["slug"], post.uuid, 14)

      # Pre-fix this raised `Ecto.MultipleResultsError`.
      found = DBStorage.find_by_url_slug(group["slug"], "en-US", "hello-multi")

      assert found != nil
      assert found.version.post.slug == "hello-multi"
      # Resolution must pick the ACTIVE version, not any of the 13 drafts.
      assert found.version.version_number == 14
    end

    test "post with many versions, only one of which has the queried custom url_slug" do
      # Active version's content has the queried slug; drafts share a stale one.
      # Pre-fix: if drafts ever shared the same slug, multiple hits crashed
      # repo().one(). The active-version scope makes that deterministic.
      {:ok, group} = Groups.add_group(unique_name(), mode: "slug")

      {:ok, post} =
        Posts.create_post(group["slug"], %{title: "Slug Drift", slug: "slug-drift"})

      [v1] = DBStorage.list_versions(post.uuid)
      [v1_content] = DBStorage.list_contents(v1.uuid)
      {:ok, _} = DBStorage.update_content(v1_content, %{url_slug: "stale-slug"})

      # Three more draft versions with the same stale slug
      for n <- 2..4 do
        {:ok, version} =
          DBStorage.create_version(%{post_uuid: post.uuid, version_number: n, status: "draft"})

        {:ok, _} =
          DBStorage.create_content(%{
            version_uuid: version.uuid,
            language: "en-US",
            title: "Slug Drift v#{n}",
            content: "v#{n}",
            status: "draft",
            url_slug: "stale-slug"
          })
      end

      # Active version has a different (current) slug
      {:ok, v5} =
        DBStorage.create_version(%{post_uuid: post.uuid, version_number: 5, status: "draft"})

      {:ok, _} =
        DBStorage.create_content(%{
          version_uuid: v5.uuid,
          language: "en-US",
          title: "Slug Drift v5",
          content: "v5",
          status: "draft",
          url_slug: "current-slug"
        })

      :ok = Versions.publish_version(group["slug"], post.uuid, 5)

      # Querying the current slug returns the active version's content.
      current = DBStorage.find_by_url_slug(group["slug"], "en-US", "current-slug")
      assert current != nil
      assert current.url_slug == "current-slug"
      assert current.version.version_number == 5

      # Querying the stale slug returns nil — only the active version is reachable.
      assert DBStorage.find_by_url_slug(group["slug"], "en-US", "stale-slug") == nil
    end

    test "unpublished posts do NOT resolve through the public URL lookup" do
      # Public URLs only reach published content. An unpublished post that
      # was reachable in the pre-split version of this query is now
      # invisible to public routing — drafts must use the `_any_version`
      # variant (next describe block) intended for admin / self-healing
      # paths. This test pins the split semantic.
      {:ok, group} = Groups.add_group(unique_name(), mode: "slug")

      {:ok, _post} =
        Posts.create_post(group["slug"], %{
          title: "Public Cant See Drafts",
          slug: "public-cant-see-drafts"
        })

      # No `Versions.publish_version/3` call — active_version_uuid stays nil.
      assert DBStorage.find_by_url_slug(group["slug"], "en-US", "public-cant-see-drafts") == nil
    end
  end

  # ============================================================================
  # find_by_url_slug — tie-breaker auto-rename
  # ============================================================================

  describe "find_by_url_slug/3 — tie-breaker auto-rename" do
    test "renames the loser's url_slug with `-2` when two published posts collide" do
      # Two distinct published posts in the same group share the same
      # custom `url_slug` in the same language. Posts.SlugHelpers normally
      # prevents this at create-time, but if a collision somehow lands in
      # the DB (race condition, manual SQL, migration leftovers), the
      # public lookup must:
      #   * still return a deterministic single row
      #   * silently rename the loser so the next request resolves cleanly
      {:ok, group} = Groups.add_group(unique_name(), mode: "slug")

      {:ok, older_post} =
        Posts.create_post(group["slug"], %{title: "Older Collider", slug: "older-collider"})

      [older_v] = DBStorage.list_versions(older_post.uuid)
      [older_content] = DBStorage.list_contents(older_v.uuid)
      {:ok, _} = DBStorage.update_content(older_content, %{url_slug: "duplicate-slug"})
      :ok = Versions.publish_version(group["slug"], older_post.uuid, older_v.version_number)

      # UUIDv7-based ordering is monotonic; the second-created post is
      # guaranteed to sort after the first regardless of clock precision,
      # so no `Process.sleep` is needed to keep the tie-break deterministic.
      {:ok, newer_post} =
        Posts.create_post(group["slug"], %{title: "Newer Collider", slug: "newer-collider"})

      [newer_v] = DBStorage.list_versions(newer_post.uuid)
      [newer_content] = DBStorage.list_contents(newer_v.uuid)
      # Bypass SlugHelpers and force the duplicate directly.
      {:ok, _} = DBStorage.update_content(newer_content, %{url_slug: "duplicate-slug"})
      :ok = Versions.publish_version(group["slug"], newer_post.uuid, newer_v.version_number)

      # First call: the OLDER (incumbent) post wins (order_by p.uuid ASC), the
      # newer one loses → its url_slug becomes "duplicate-slug-2".
      winner = DBStorage.find_by_url_slug(group["slug"], "en-US", "duplicate-slug")
      assert winner != nil
      assert winner.version.post.slug == "older-collider"

      # Loser (the NEWER post) got its url_slug renamed in place.
      reloaded_newer = DBStorage.list_contents(newer_v.uuid) |> List.first()
      assert reloaded_newer.url_slug == "duplicate-slug-2"

      # Subsequent lookup is clean — only one row matches "duplicate-slug".
      assert winner_again =
               DBStorage.find_by_url_slug(group["slug"], "en-US", "duplicate-slug")

      assert winner_again.version.post.slug == "older-collider"

      # And the renamed slug now resolves to the loser (still published).
      assert renamed =
               DBStorage.find_by_url_slug(group["slug"], "en-US", "duplicate-slug-2")

      assert renamed.version.post.slug == "newer-collider"
    end

    test "increments suffix when three posts collide on the same slug" do
      # Three-way collision. Incumbent (oldest) stays as-is; the newer two are
      # renamed `-2`, `-3`. Auto-rename's `Enum.with_index(losers, 2)` produces
      # the suffix sequence.
      {:ok, group} = Groups.add_group(unique_name(), mode: "slug")

      [{p1, _, _v1}, {_p2, _, v2}, {_p3, _, v3}] =
        for slug <- ["first", "second", "third"] do
          {:ok, post} =
            Posts.create_post(group["slug"], %{title: "Slug #{slug}", slug: "post-#{slug}"})

          [version] = DBStorage.list_versions(post.uuid)
          [content] = DBStorage.list_contents(version.uuid)
          {:ok, _} = DBStorage.update_content(content, %{url_slug: "triple-collide"})
          :ok = Versions.publish_version(group["slug"], post.uuid, version.version_number)
          {post, content, version}
        end

      # `p1` is the oldest (UUIDv7 monotonic) → the incumbent wins.
      winner = DBStorage.find_by_url_slug(group["slug"], "en-US", "triple-collide")
      assert winner.version.post.uuid == p1.uuid

      # The two NEWER posts had their slugs renamed.
      [renamed_c2] = DBStorage.list_contents(v2.uuid)
      [renamed_c3] = DBStorage.list_contents(v3.uuid)

      # Both got a suffix; with `order_by p.uuid ASC` the losers are `[p2, p3]`,
      # so `p2` (second) is `-2` and `p3` (third) is `-3`.
      renamed_slugs = MapSet.new([renamed_c2.url_slug, renamed_c3.url_slug])
      assert renamed_slugs == MapSet.new(["triple-collide-2", "triple-collide-3"])

      # Both renamed slugs are now reachable individually, and the
      # canonical slug only resolves to the winner.
      assert DBStorage.find_by_url_slug(group["slug"], "en-US", "triple-collide-2") != nil
      assert DBStorage.find_by_url_slug(group["slug"], "en-US", "triple-collide-3") != nil

      again = DBStorage.find_by_url_slug(group["slug"], "en-US", "triple-collide")
      assert again.version.post.uuid == p1.uuid
    end
  end

  # ============================================================================
  # find_by_url_slug_any_version — internal/self-healing lookup
  # ============================================================================

  describe "find_by_url_slug_any_version/3" do
    test "resolves a published post the same way the public lookup does" do
      {:ok, group} = Groups.add_group(unique_name(), mode: "slug")

      {:ok, post} =
        Posts.create_post(group["slug"], %{title: "Published Any", slug: "published-any"})

      [version] = DBStorage.list_versions(post.uuid)
      :ok = Versions.publish_version(group["slug"], post.uuid, version.version_number)

      assert DBStorage.find_by_url_slug_any_version(group["slug"], "en-US", "published-any") !=
               nil
    end

    test "resolves an unpublished post (drafts ARE findable through this variant)" do
      {:ok, group} = Groups.add_group(unique_name(), mode: "slug")

      {:ok, post} =
        Posts.create_post(group["slug"], %{title: "Draft Any", slug: "draft-any"})

      # Never published — active_version_uuid stays nil. Public lookup
      # returns nil; `_any_version` surfaces the draft.
      assert DBStorage.find_by_url_slug(group["slug"], "en-US", "draft-any") == nil

      found = DBStorage.find_by_url_slug_any_version(group["slug"], "en-US", "draft-any")
      assert found != nil
      assert found.version.post.uuid == post.uuid
    end

    test "draft with many versions returns the latest version (no auto-rename)" do
      # The draft-self-healing flow expects to find SOMETHING when a post
      # has accumulated multiple drafts sharing slug/language. Unlike the
      # public lookup, no auto-rename happens — drafts may legitimately
      # share slugs while being authored.
      {:ok, group} = Groups.add_group(unique_name(), mode: "slug")

      {:ok, post} =
        Posts.create_post(group["slug"], %{title: "Draft Multi", slug: "draft-multi"})

      [v1] = DBStorage.list_versions(post.uuid)
      [v1_content] = DBStorage.list_contents(v1.uuid)
      {:ok, _} = DBStorage.update_content(v1_content, %{url_slug: ""})

      for n <- 2..5 do
        {:ok, version} =
          DBStorage.create_version(%{post_uuid: post.uuid, version_number: n, status: "draft"})

        {:ok, _} =
          DBStorage.create_content(%{
            version_uuid: version.uuid,
            language: "en-US",
            title: "Draft Multi v#{n}",
            content: "v#{n}",
            status: "draft",
            url_slug: ""
          })
      end

      found = DBStorage.find_by_url_slug_any_version(group["slug"], "en-US", "draft-multi")
      assert found != nil
      assert found.version.version_number == 5

      # All five draft versions still hold the original empty url_slug —
      # nothing got renamed (auto-rename only applies to the public lookup).
      for version <- DBStorage.list_versions(post.uuid) do
        [content] = DBStorage.list_contents(version.uuid)
        assert content.url_slug in [nil, ""]
      end
    end

    test "two unpublished posts colliding on slug — returns one deterministically (no auto-rename)" do
      # This is the gap Codex flagged: across-post collisions in the
      # draft state. The `_any_version` variant does NOT auto-rename
      # (drafts can legitimately share slugs while being authored), but
      # it must still return a single row deterministically. The query's
      # `order_by [desc: v.version_number] + limit: 1` picks one.
      #
      # The "loser" stays as-is — uniqueness is enforced when the user
      # later tries to PUBLISH the colliding draft (via SlugHelpers'
      # `url_slug_exists?` check, which now uses this any-version
      # variant and so sees the collision).
      {:ok, group} = Groups.add_group(unique_name(), mode: "slug")

      for slug <- ["draft-a", "draft-b"] do
        {:ok, post} =
          Posts.create_post(group["slug"], %{title: "Draft #{slug}", slug: "post-#{slug}"})

        [version] = DBStorage.list_versions(post.uuid)
        [content] = DBStorage.list_contents(version.uuid)
        {:ok, _} = DBStorage.update_content(content, %{url_slug: "draft-collide"})
      end

      # Doesn't crash; returns ONE of the two drafts deterministically.
      found = DBStorage.find_by_url_slug_any_version(group["slug"], "en-US", "draft-collide")
      assert found != nil
      assert found.url_slug == "draft-collide"

      # Neither was renamed — the collision is acceptable in draft state.
      all_with_slug =
        from(c in PhoenixKit.Modules.Publishing.PublishingContent,
          where: c.url_slug == "draft-collide"
        )
        |> PhoenixKit.RepoHelper.repo().all()

      assert length(all_with_slug) == 2
    end
  end

  # ============================================================================
  # find_by_previous_url_slug — 301 redirect support
  # ============================================================================

  describe "find_by_previous_url_slug/3" do
    test "finds a post by a slug previously assigned to its content" do
      {:ok, group} = Groups.add_group(unique_name(), mode: "slug")

      {:ok, post} =
        Posts.create_post(group["slug"], %{title: "Renamed Post", slug: "renamed-post"})

      [version] = DBStorage.list_versions(post.uuid)
      [content] = DBStorage.list_contents(version.uuid)

      # Simulate a content row that used to live at "old-slug" before being renamed.
      {:ok, _} =
        DBStorage.update_content(content, %{
          url_slug: "new-slug",
          data: %{"previous_url_slugs" => ["old-slug"]}
        })

      :ok = Versions.publish_version(group["slug"], post.uuid, version.version_number)

      found = DBStorage.find_by_previous_url_slug(group["slug"], "en-US", "old-slug")
      assert found != nil
      assert found.url_slug == "new-slug"
      assert found.version.post.slug == "renamed-post"
    end

    test "returns nil when no content's previous_url_slugs match" do
      {:ok, group} = Groups.add_group(unique_name(), mode: "slug")
      assert DBStorage.find_by_previous_url_slug(group["slug"], "en-US", "never") == nil
    end

    test "returns nil for trashed posts even if previous_url_slugs matches" do
      {:ok, group} = Groups.add_group(unique_name(), mode: "slug")

      {:ok, post} =
        Posts.create_post(group["slug"], %{title: "Trashed Renamed", slug: "trashed-renamed"})

      [version] = DBStorage.list_versions(post.uuid)
      [content] = DBStorage.list_contents(version.uuid)

      {:ok, _} =
        DBStorage.update_content(content, %{
          data: %{"previous_url_slugs" => ["was-here"]}
        })

      :ok = Versions.publish_version(group["slug"], post.uuid, version.version_number)
      {:ok, _} = Posts.trash_post(group["slug"], post.uuid)

      assert DBStorage.find_by_previous_url_slug(group["slug"], "en-US", "was-here") == nil
    end

    test "returns nil for an unpublished post even if previous_url_slugs matches" do
      # Public 301-redirect path: a post that was never published has no
      # active version and is unreachable from a public URL, so resolving
      # its previous slug would just redirect a visitor onto a 404.
      {:ok, group} = Groups.add_group(unique_name(), mode: "slug")

      {:ok, post} =
        Posts.create_post(group["slug"], %{title: "Never Published", slug: "never-published"})

      [version] = DBStorage.list_versions(post.uuid)
      [content] = DBStorage.list_contents(version.uuid)

      {:ok, _} =
        DBStorage.update_content(content, %{
          data: %{"previous_url_slugs" => ["draft-old-slug"]}
        })

      # Deliberately NOT calling Versions.publish_version/3.
      assert DBStorage.find_by_previous_url_slug(group["slug"], "en-US", "draft-old-slug") == nil
    end

    test "returns nil for a different language than the row that holds the previous slug" do
      {:ok, group} = Groups.add_group(unique_name(), mode: "slug")

      {:ok, post} =
        Posts.create_post(group["slug"], %{title: "Lang Scoped", slug: "lang-scoped"})

      [version] = DBStorage.list_versions(post.uuid)
      [content] = DBStorage.list_contents(version.uuid)

      {:ok, _} =
        DBStorage.update_content(content, %{
          data: %{"previous_url_slugs" => ["english-only-old"]}
        })

      :ok = Versions.publish_version(group["slug"], post.uuid, version.version_number)

      # The previous-slug entry only exists on the en-US row.
      assert DBStorage.find_by_previous_url_slug(group["slug"], "de-DE", "english-only-old") ==
               nil
    end

    test "post with many versions sharing a previous slug resolves to a single row" do
      # Same regression class as `find_by_url_slug`: previously the join
      # spanned every version, so a post with several historical versions
      # carrying `previous_url_slugs: ["old-slug"]` in their JSONB would
      # crash `repo().one()`.
      {:ok, group} = Groups.add_group(unique_name(), mode: "slug")

      {:ok, post} =
        Posts.create_post(group["slug"], %{title: "Prev Slug Multi", slug: "prev-slug-multi"})

      [v1] = DBStorage.list_versions(post.uuid)
      [v1_content] = DBStorage.list_contents(v1.uuid)

      {:ok, _} =
        DBStorage.update_content(v1_content, %{
          data: %{"previous_url_slugs" => ["old-prev"]}
        })

      for n <- 2..5 do
        {:ok, version} =
          DBStorage.create_version(%{post_uuid: post.uuid, version_number: n, status: "draft"})

        {:ok, _} =
          DBStorage.create_content(%{
            version_uuid: version.uuid,
            language: "en-US",
            title: "Prev Multi v#{n}",
            content: "v#{n}",
            status: "draft",
            data: %{"previous_url_slugs" => ["old-prev"]}
          })
      end

      :ok = Versions.publish_version(group["slug"], post.uuid, 5)

      found = DBStorage.find_by_previous_url_slug(group["slug"], "en-US", "old-prev")
      assert found != nil
      assert found.version.version_number == 5
    end
  end

  # ============================================================================
  # find_by_url_slug — round-trip via `Posts.find_by_url_slug`
  # ============================================================================

  describe "Posts.find_by_url_slug/3 — controller-facing wrapper" do
    test "wraps DBStorage hit in {:ok, post_map}" do
      {:ok, group} = Groups.add_group(unique_name(), mode: "slug")

      {:ok, post} =
        Posts.create_post(group["slug"], %{title: "Wrapped", slug: "wrapped"})

      [version] = DBStorage.list_versions(post.uuid)
      :ok = Versions.publish_version(group["slug"], post.uuid, version.version_number)

      assert {:ok, post_map} = Posts.find_by_url_slug(group["slug"], "en-US", "wrapped")
      assert post_map.slug == "wrapped"
      assert post_map.language == "en-US"
    end

    test "wraps DBStorage miss in {:error, :not_found}" do
      {:ok, group} = Groups.add_group(unique_name(), mode: "slug")

      assert {:error, :not_found} =
               Posts.find_by_url_slug(group["slug"], "en-US", "definitely-not-here")
    end

    test "controller-facing wrapper survives the 14-version regression case end-to-end" do
      # Mirror the regression test above but at the `Posts.find_by_url_slug`
      # level — proves the wrapper, not just `DBStorage`, doesn't blow up.
      {:ok, group} = Groups.add_group(unique_name(), mode: "slug")

      {:ok, post} =
        Posts.create_post(group["slug"], %{title: "Wrapper Multi", slug: "wrapper-multi"})

      for n <- 2..14 do
        {:ok, version} =
          DBStorage.create_version(%{post_uuid: post.uuid, version_number: n, status: "draft"})

        {:ok, _} =
          DBStorage.create_content(%{
            version_uuid: version.uuid,
            language: "en-US",
            title: "Wrapper Multi v#{n}",
            content: "v#{n}",
            status: "draft",
            url_slug: ""
          })
      end

      :ok = Versions.publish_version(group["slug"], post.uuid, 14)

      assert {:ok, post_map} = Posts.find_by_url_slug(group["slug"], "en-US", "wrapper-multi")
      assert post_map.slug == "wrapper-multi"
    end
  end
end
