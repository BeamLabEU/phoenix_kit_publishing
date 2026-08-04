defmodule PhoenixKit.Modules.Publishing.Web.Controller.DesignDecisionsTest do
  @moduledoc """
  Pins the 2026-08 design-round outcomes (panel-reviewed):

  - canonical-prefix 301 parity for search, term archives, and feeds
    (feed-to-feed only — never the HTML smart fallback);
  - the StaleFixer merge stashing a divergent discarded legacy body under
    `data["_stale_fixer"]`, and that stash surviving a subsequent edit
    (whitelisted in Posts' content-data preservation);
  - the read-side V1-legacy fallback for `featured_image_uuid`/`description`
    (version wins; absent version key falls back to the rendered language's
    own content.data value; promotion-on-edit converges it);
  - CacheSync erasing the local listing cache on `{:cache_invalidated, _}`.
  """

  # async: false — mutates the global publishing + language settings rows.
  use PhoenixKitPublishing.ConnCase, async: false

  alias PhoenixKit.Modules.Publishing.DBStorage
  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.ListingCache
  alias PhoenixKit.Modules.Publishing.ListingCache.CacheSync
  alias PhoenixKit.Modules.Publishing.Posts
  alias PhoenixKit.Modules.Publishing.Versions
  alias PhoenixKit.Settings

  defp unique_name(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp base_settings do
    {:ok, _} = Settings.update_boolean_setting("publishing_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("publishing_public_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("publishing_feeds_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("languages_enabled", false)
    {:ok, _} = Settings.update_setting("content_language", "en")
    :ok
  end

  # get_content_language ignores the raw setting: with languages disabled it
  # hard-returns "en", otherwise it reads languages_config's default. Tests
  # that need an en-US primary must enable the module with a real config.
  defp enable_dialect_primary do
    {:ok, _} = Settings.update_boolean_setting("publishing_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("publishing_public_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("languages_enabled", true)
    {:ok, _} = Settings.update_setting("content_language", "en-US")

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

    :ok
  end

  defp with_no_prefix(fun) do
    {:ok, _} = Settings.update_boolean_setting("default_language_no_prefix", true)

    try do
      fun.()
    after
      {:ok, _} = Settings.update_boolean_setting("default_language_no_prefix", false)
    end
  end

  defp published_post(group_slug, attrs) do
    {:ok, post} = Posts.create_post(group_slug, attrs)
    :ok = Versions.publish_version(group_slug, post.uuid, 1)
    post
  end

  describe "canonical-prefix parity (default_language_no_prefix on)" do
    setup do
      base_settings()
      {:ok, group} = Groups.add_group(unique_name("canon"), mode: "slug")
      slug = group["slug"]
      published_post(slug, %{title: "Canon", slug: "canon", content: "Body #tagged here."})
      {:ok, _} = Groups.update_group(slug, %{"search_enabled" => true})
      %{group_slug: slug}
    end

    test "search results 301 to the prefixless form, keeping the query", %{
      conn: conn,
      group_slug: slug
    } do
      with_no_prefix(fn ->
        conn = get(conn, "/en/#{slug}?q=body")
        assert conn.status == 301
        location = get_resp_header(conn, "location") |> List.first()
        assert location =~ "/#{slug}"
        assert location =~ "q=body"
      end)
    end

    test "tag archives 301 to the prefixless form", %{conn: conn, group_slug: slug} do
      with_no_prefix(fn ->
        conn = get(conn, "/en/#{slug}/tag/tagged")
        assert conn.status == 301
        assert get_resp_header(conn, "location") |> List.first() =~ "/#{slug}/tag/tagged"
      end)
    end

    test "feeds 301 feed-to-feed, never into HTML", %{conn: conn, group_slug: slug} do
      with_no_prefix(fn ->
        conn = get(conn, "/en/#{slug}/feed.xml")
        assert conn.status == 301
        location = get_resp_header(conn, "location") |> List.first()
        assert location == "/#{slug}/feed.xml"
      end)
    end
  end

  describe "merge stash for discarded legacy bodies" do
    test "a divergent legacy body survives in data[_stale_fixer] and outlives an edit" do
      enable_dialect_primary()

      {:ok, group} = Groups.add_group(unique_name("merge"), mode: "slug")
      slug = group["slug"]
      post = published_post(slug, %{title: "Target", slug: "target", content: "Target body."})

      # A legacy base-code row for the same version with a DIFFERENT body —
      # the read-path heal merges it into the en-US row and deletes it.
      [version] = DBStorage.list_versions(post.uuid)

      {:ok, _} =
        DBStorage.create_content(%{
          version_uuid: version.uuid,
          language: "en",
          title: "Legacy Title",
          content: "Divergent legacy body that must not vanish.",
          status: "published"
        })

      {:ok, healed} = Posts.read_post_by_uuid(post.uuid, "en-US", 1)
      assert healed.language == "en-US"

      content = DBStorage.get_content(version.uuid, "en-US")
      [entry] = get_in(content.data, ["_stale_fixer", "discarded"])
      assert entry["discarded_content"] =~ "Divergent legacy body"
      assert entry["from_language"] == "en"

      # The stash must survive a subsequent edit (whitelist membership) —
      # before that, the first save wiped the only copy.
      {:ok, read} = Posts.read_post_by_uuid(post.uuid, "en-US", 1)
      {:ok, _} = Posts.update_post(slug, read, %{"content" => "Edited body."}, %{})

      content_after = DBStorage.get_content(version.uuid, "en-US")
      assert get_in(content_after.data, ["_stale_fixer", "discarded"]) != nil
    end
  end

  describe "V1-legacy read-side fallback" do
    test "content-level featured image and description surface until promotion" do
      enable_dialect_primary()

      {:ok, group} = Groups.add_group(unique_name("legacy"), mode: "slug")
      slug = group["slug"]
      post = published_post(slug, %{title: "Legacy", slug: "legacy", content: "Legacy body."})

      [version] = DBStorage.list_versions(post.uuid)
      content = DBStorage.get_content(version.uuid, "en-US")
      image_uuid = Ecto.UUID.generate()

      {:ok, _} =
        DBStorage.update_content(content, %{
          data:
            Map.merge(content.data || %{}, %{
              "featured_image_uuid" => image_uuid,
              "description" => "Legacy per-language description"
            })
        })

      {:ok, read} = Posts.read_post_by_uuid(post.uuid, "en-US", 1)
      assert read.metadata.featured_image_uuid == image_uuid
      assert read.metadata.description == "Legacy per-language description"

      # An edit promotes to the version and the values stay identical.
      {:ok, _} = Posts.update_post(slug, read, %{"content" => "Edited."}, %{})
      {:ok, promoted} = Posts.read_post_by_uuid(post.uuid, "en-US", 1)
      assert promoted.metadata.featured_image_uuid == image_uuid
      assert promoted.metadata.description == "Legacy per-language description"

      [version_after] = DBStorage.list_versions(post.uuid)
      assert (version_after.data || %{})["featured_image_uuid"] == image_uuid
    end
  end

  describe "CacheSync" do
    test "erases the local listing cache on a cache_invalidated message" do
      base_settings()
      {:ok, group} = Groups.add_group(unique_name("sync"), mode: "slug")
      slug = group["slug"]
      published_post(slug, %{title: "Cached", slug: "cached", content: "Body."})

      :ok = ListingCache.regenerate(slug, broadcast: false)
      assert ListingCache.cache_generated_at(slug) != nil

      pid = start_supervised!(CacheSync)
      send(pid, {:cache_invalidated, slug})
      # Synchronize with the GenServer before asserting.
      :sys.get_state(pid)

      assert ListingCache.cache_generated_at(slug) == nil
    end
  end
end
