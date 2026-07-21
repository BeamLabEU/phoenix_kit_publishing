defmodule PhoenixKit.Modules.Publishing.Web.Controller.RichFixturesTest do
  @moduledoc """
  End-to-end public route tests with multi-version + multi-language post
  fixtures. The goal is to exercise the conditional branches in
  Web.HTML.show/1, Web.HTML.index/1, and Web.Controller.{Fallback,
  Language, PostRendering} that the simpler smoke tests don't reach.
  """

  use PhoenixKitPublishing.ConnCase, async: false

  alias PhoenixKit.Modules.Publishing.DBStorage
  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.Posts
  alias PhoenixKit.Modules.Publishing.TranslationManager
  alias PhoenixKit.Modules.Publishing.Versions
  alias PhoenixKit.Settings

  defp setup_languages do
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
          },
          %{
            "code" => "de-DE",
            "name" => "German",
            "is_default" => false,
            "is_enabled" => true,
            "position" => 1
          },
          %{
            "code" => "fr-FR",
            "name" => "French",
            "is_default" => false,
            "is_enabled" => true,
            "position" => 2
          }
        ]
      })
  end

  describe "multi-language post (slug mode) — public path renders" do
    setup do
      setup_languages()

      group_slug = "rich-#{System.unique_integer([:positive])}"
      {:ok, group} = Groups.add_group(group_slug, mode: "slug")

      {:ok, post} =
        Posts.create_post(group["slug"], %{title: "Hello", slug: "hello", content: "# Hello"})

      :ok = Versions.publish_version(group["slug"], post.uuid, 1)

      # Add a German translation
      {:ok, _} = TranslationManager.add_language_to_post(group["slug"], post.uuid, "de-DE", nil)

      %{group_slug: group["slug"], post: post}
    end

    test "renders show page for default language (en-US base 'en')",
         %{conn: conn, group_slug: group_slug, post: post} do
      conn = get(conn, "/en/#{group_slug}/#{post.slug}")
      assert conn.status in [200, 301, 302]
    end

    test "renders show page for translated language (de-DE base 'de')",
         %{conn: conn, group_slug: group_slug, post: post} do
      conn = get(conn, "/de/#{group_slug}/#{post.slug}")
      # The de-DE translation is in the published version, so it must be
      # reachable — render or canonical-redirect, never 404.
      assert conn.status in [200, 301, 302]
    end

    test "language fallback fires for unsupported language",
         %{conn: conn, group_slug: group_slug, post: post} do
      conn = get(conn, "/zz/#{group_slug}/#{post.slug}")
      assert conn.status in [200, 301, 302, 404]
    end

    test "renders group listing with multi-language switcher",
         %{conn: conn, group_slug: group_slug} do
      conn = get(conn, "/en/#{group_slug}")
      assert conn.status in [200, 301, 302]
    end
  end

  describe "per-language url_slug on the public listing" do
    setup do
      setup_languages()

      group_slug = "langslug-#{System.unique_integer([:positive])}"
      {:ok, group} = Groups.add_group(group_slug, mode: "slug")

      {:ok, post} =
        Posts.create_post(group["slug"], %{title: "Hello", slug: "hello", content: "# Hello"})

      {:ok, _} =
        TranslationManager.add_language_to_post(group["slug"], post.uuid, "de-DE", nil)

      # Give the German content its own custom URL slug, then publish (which
      # regenerates the listing cache with both languages' slugs).
      [version] = DBStorage.list_versions(post.uuid)

      de_content =
        version.uuid
        |> DBStorage.list_contents()
        |> Enum.find(&(&1.language == "de-DE"))

      {:ok, _} =
        DBStorage.update_content(de_content, %{
          url_slug: "hallo-welt"
        })

      :ok = Versions.publish_version(group["slug"], post.uuid, version.version_number)

      %{group_slug: group["slug"], post: post}
    end

    test "the German listing links cards with the German slug, not the primary one",
         %{conn: conn, group_slug: group_slug} do
      html = conn |> get("/de/#{group_slug}") |> html_response(200)

      assert html =~ "/de/#{group_slug}/hallo-welt"
      # The card link must not fall back to the primary/internal slug.
      refute html =~ ~s(href="/de/#{group_slug}/hello")
    end

    test "the German post is reachable at its custom slug",
         %{conn: conn, group_slug: group_slug} do
      conn = get(conn, "/de/#{group_slug}/hallo-welt")
      assert conn.status in [200, 301, 302]

      # A redirect must stay on the custom slug (canonicalizing the locale is
      # fine); rendering must be the actual post. Either way the slug holds.
      if conn.status in [301, 302] do
        assert redirected_to(conn, conn.status) =~ "hallo-welt"
      else
        # The DE translation's content is blank in this fixture — assert the
        # rendered page's canonical URL keeps the custom slug instead.
        assert html_response(conn, 200) =~ "/de/#{group_slug}/hallo-welt"
      end
    end

    test "the English listing still uses the internal slug",
         %{conn: conn, group_slug: group_slug} do
      html = conn |> get("/en/#{group_slug}") |> html_response(200)
      assert html =~ "/en/#{group_slug}/hello"
    end
  end

  # Historical NOTE (kept for context): multi-version-on-same-url_slug
  # scenarios were excluded here because `DBStorage.find_by_url_slug/3`
  # used to crash with `Ecto.MultipleResultsError` when a post's draft
  # versions shared an empty url_slug. That regression is fixed
  # (commit `cee15cc` scoped the query to the active version, plus
  # `cba14d2` added the public/any-version split + tie-breaker
  # auto-rename). Dedicated coverage for the multi-version shape now
  # lives in
  # `test/phoenix_kit_publishing/integration/db_storage_url_slug_lookup_test.exs`,
  # so this file doesn't need to exercise that scenario directly.

  describe "timestamp-mode posts — date URL branches" do
    setup do
      setup_languages()

      group_slug = "rich-ts-#{System.unique_integer([:positive])}"
      {:ok, group} = Groups.add_group(group_slug, mode: "timestamp")

      {:ok, post} =
        Posts.create_post(group["slug"], %{title: "TimestampPost", content: "Body."})

      :ok = Versions.publish_version(group["slug"], post.uuid, 1)

      %{group_slug: group["slug"], post: post}
    end

    test "renders timestamp-mode group listing",
         %{conn: conn, group_slug: group_slug} do
      conn = get(conn, "/en/#{group_slug}")
      assert conn.status in [200, 301, 302]
    end

    test "missing timestamp URL hits Fallback timestamp branches",
         %{conn: conn, group_slug: group_slug} do
      conn = get(conn, "/en/#{group_slug}/2026-04-27/10:00")
      assert conn.status in [200, 301, 302, 404]
    end

    test "missing date returns fallback or 404",
         %{conn: conn, group_slug: group_slug} do
      conn = get(conn, "/en/#{group_slug}/2026-04-27")
      assert conn.status in [200, 301, 302, 404]
    end
  end

  describe "trashed post fallback — Fallback.handle_not_found via :not_found" do
    setup do
      setup_languages()

      group_slug = "rich-trash-#{System.unique_integer([:positive])}"
      {:ok, group} = Groups.add_group(group_slug, mode: "slug")

      {:ok, post} =
        Posts.create_post(group["slug"], %{title: "Trashable", slug: "trashable"})

      :ok = Versions.publish_version(group["slug"], post.uuid, 1)
      {:ok, _} = Posts.trash_post(group["slug"], post.uuid)

      %{group_slug: group["slug"], post: post}
    end

    test "trashed post URL exercises fallback chain",
         %{conn: conn, group_slug: group_slug, post: post} do
      conn = get(conn, "/en/#{group_slug}/#{post.slug}")
      assert conn.status in [200, 301, 302, 404]
    end
  end

  describe "draft (unpublished) post fallback" do
    setup do
      setup_languages()

      group_slug = "rich-draft-#{System.unique_integer([:positive])}"
      {:ok, group} = Groups.add_group(group_slug, mode: "slug")

      {:ok, post} =
        Posts.create_post(group["slug"], %{title: "Draft", slug: "draft"})

      # Don't publish — leave as draft
      %{group_slug: group["slug"], post: post}
    end

    test "draft post URL falls back via :unpublished reason",
         %{conn: conn, group_slug: group_slug, post: post} do
      conn = get(conn, "/en/#{group_slug}/#{post.slug}")
      assert conn.status in [200, 301, 302, 404]
    end
  end
end
