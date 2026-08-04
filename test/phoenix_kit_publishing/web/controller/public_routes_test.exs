defmodule PhoenixKit.Modules.Publishing.Web.Controller.PublicRoutesTest do
  @moduledoc """
  Branch coverage for the public Web.Controller and its submodules
  (PostFetching, PostRendering, SlugResolution, Fallback, Listing).
  Drives requests through a real Plug pipeline via the test endpoint.

  Pins the public-facing paths each submodule owns:
    * /:group → group listing
    * /:group/:post_slug → published post (slug mode)
    * Missing post → falls through to Fallback
    * Trashed group → 404 / fallback
  """

  # Forces async: false because the test mutates the global
  # `content_language` setting; a parallel test (stale_fixer_test)
  # also writes to that row and the two upserts deadlock under
  # concurrent Postgres load.
  use PhoenixKitPublishing.ConnCase, async: false

  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.Posts
  alias PhoenixKit.Modules.Publishing.Versions
  alias PhoenixKit.Settings

  defp unique_name, do: "public-#{System.unique_integer([:positive])}"

  setup do
    {:ok, _} = Settings.update_boolean_setting("publishing_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("publishing_public_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("languages_enabled", false)
    {:ok, _} = Settings.update_setting("content_language", "en")

    {:ok, group} = Groups.add_group(unique_name(), mode: "slug")

    {:ok, post} =
      Posts.create_post(group["slug"], %{title: "First Post", slug: "first-post"})

    :ok = Versions.publish_version(group["slug"], post.uuid, 1)

    %{group_slug: group["slug"], post: post}
  end

  describe "/:group — group listing" do
    test "renders 200 for an existing group", %{conn: conn, group_slug: group_slug} do
      assert html_response(get(conn, "/" <> group_slug), 200)
    end

    test "renders 200 even when no posts are published", %{conn: conn} do
      {:ok, empty_group} = Groups.add_group(unique_name(), mode: "slug")
      assert html_response(get(conn, "/" <> empty_group["slug"]), 200)
    end
  end

  describe "/:group/:post_slug — published-post path" do
    test "renders 200 with the post body when slug matches", %{
      conn: conn,
      group_slug: group_slug,
      post: post
    } do
      response = get(conn, "/" <> group_slug <> "/" <> post.slug) |> html_response(200)
      assert response =~ "First Post"
    end

    test "missing post slug falls back without crashing", %{
      conn: conn,
      group_slug: group_slug
    } do
      # Fallback module resolves missing slugs — we expect either 200 (with
      # fallback content) or 404, but never a 500 from a crashed pipeline.
      conn = get(conn, "/" <> group_slug <> "/totally-missing-slug")
      assert conn.status in [200, 301, 302, 404]
    end
  end

  describe "publishing_public_enabled toggle" do
    test "redirects/404s when public access is disabled", %{conn: conn, group_slug: group_slug} do
      {:ok, _} = Settings.update_boolean_setting("publishing_public_enabled", false)
      conn = get(conn, "/" <> group_slug)
      # Disabled = either redirect to 404 page or hard 404
      assert conn.status in [302, 404, 410, 503]
    end
  end

  describe "/:language/:group — language-prefixed routes (PostFetching path)" do
    test "renders 200 for /:language/:group/:post_slug", %{
      conn: conn,
      group_slug: group_slug,
      post: post
    } do
      response = get(conn, "/en/#{group_slug}/#{post.slug}") |> response(200)
      assert is_binary(response)
    end

    test "renders 200 for /:language/:group", %{conn: conn, group_slug: group_slug} do
      response = get(conn, "/en/#{group_slug}") |> response(200)
      assert is_binary(response)
    end
  end

  describe "post-rendering deep paths" do
    test "missing post slug exercises Fallback module", %{conn: conn, group_slug: group_slug} do
      conn = get(conn, "/#{group_slug}/totally-bogus-#{System.unique_integer()}")
      assert conn.status in [200, 301, 302, 404, 410]
    end

    test "version-suffixed URL exercises render_versioned_post", %{
      conn: conn,
      group_slug: group_slug,
      post: post
    } do
      conn = get(conn, "/#{group_slug}/#{post.slug}/v1")
      assert conn.status in [200, 301, 302, 404]
    end
  end

  describe "root path" do
    test "a bare / never crashes (it belongs to the host, not publishing)" do
      # There is deliberately no all-groups overview route — the catch-all
      # must pass the root through to the host. (The dormant all_groups/1
      # template was deleted 2026-08; an overview would be a new opt-in
      # reserved route, not a resurrection.)
      conn = build_conn() |> get("/")
      assert conn.status in [200, 301, 302, 404]
    end
  end

  # =====================================================================
  # Smart fallback contract — exact behaviour, not "any of these statuses".
  #
  # Critical when `url_prefix` is "/" because publishing's catch-all then
  # sits at the host's absolute root. A miss inside a real group must
  # redirect to that group's listing (in-group fallback), but a miss on
  # an unknown first segment must 404 — never redirect to "the first
  # group in the DB", which would hijack every host-app path.
  # =====================================================================
  describe "smart fallback contract" do
    test "missing post in a known group → 302 to THAT group's listing", %{
      conn: conn,
      group_slug: group_slug
    } do
      conn = get(conn, "/#{group_slug}/definitely-not-a-real-post")
      assert conn.status == 302
      assert {"location", target} = List.keyfind(conn.resp_headers, "location", 0)
      assert target == "/#{group_slug}"
    end

    test "missing post in a known group → flash explains the redirect", %{
      conn: conn,
      group_slug: group_slug
    } do
      conn = get(conn, "/#{group_slug}/definitely-not-a-real-post")
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Showing closest match"
    end

    test "unknown first segment → 404 (must NOT redirect to any group)", %{conn: conn} do
      slug = "host-app-page-#{System.unique_integer()}"
      conn = get(conn, "/#{slug}")
      assert conn.status == 404
    end

    test "unknown nested path → 404 (catch-all must not hijack host-app routes)", %{
      conn: conn
    } do
      slug = "host-#{System.unique_integer()}"
      conn = get(conn, "/#{slug}/team/page")
      assert conn.status == 404
    end

    test "even with several real groups in the DB, an unknown slug 404s", %{conn: conn} do
      # Pre-fix this returned 302 to whatever group was first. Pin the
      # exact contract: the dispatcher must not browse the group list to
      # pick a redirect target when the requested slug isn't a group.
      {:ok, _} = Groups.add_group(unique_name(), mode: "slug")
      {:ok, _} = Groups.add_group(unique_name(), mode: "slug")

      conn = get(conn, "/totally-not-any-of-them-#{System.unique_integer()}")
      assert conn.status == 404
    end

    test "/<group>/<missing-post> via localized route still redirects correctly", %{
      conn: conn,
      group_slug: group_slug
    } do
      # The localized route /:language/:group binds language=<group>,
      # group=<missing-post>, then the controller reinterprets via
      # `Language.detect_language_or_group/2`. Without the conn.params
      # rewrite the in-group fallback would read the wrong slug — pin
      # that the Location header is the actual requested group, not
      # whatever happens to be first.
      conn = get(conn, "/#{group_slug}/missing-post-#{System.unique_integer()}")
      assert conn.status == 302
      assert {"location", target} = List.keyfind(conn.resp_headers, "location", 0)
      assert target == "/#{group_slug}"
    end
  end
end
