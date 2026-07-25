defmodule PhoenixKit.Modules.Publishing.Web.Controller.FeedTest do
  @moduledoc """
  Pins the RSS feed contract: `/<group>/feed.xml` serves RSS 2.0 for the
  group's published posts, 404s hard (no smart fallback) on unknown groups or
  the kill-switch, and escapes/CDATA-wraps all dynamic content.
  """

  # async: false — mutates the global publishing settings rows.
  use PhoenixKitPublishing.ConnCase, async: false

  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.Posts
  alias PhoenixKit.Modules.Publishing.Versions
  alias PhoenixKit.Settings

  defp unique_name, do: "feed-#{System.unique_integer([:positive])}"

  setup do
    {:ok, _} = Settings.update_boolean_setting("publishing_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("publishing_public_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("publishing_feeds_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("languages_enabled", false)
    {:ok, _} = Settings.update_setting("content_language", "en")

    {:ok, group} = Groups.add_group(unique_name(), mode: "slug")

    {:ok, post} =
      Posts.create_post(group["slug"], %{
        title: "Feed Post <One> & Co",
        slug: "feed-post-one",
        content: "Body of the feed post."
      })

    :ok = Versions.publish_version(group["slug"], post.uuid, 1)

    %{group_slug: group["slug"], post: post}
  end

  test "serves RSS 2.0 with escaped titles and permalink guids", %{
    conn: conn,
    group_slug: slug
  } do
    conn = get(conn, "/#{slug}/feed.xml")

    assert rss_content_type(conn) =~ "application/rss+xml"
    body = response(conn, 200)

    assert body =~ ~s(<?xml version="1.0" encoding="UTF-8"?>)
    assert body =~ ~s(<rss version="2.0")
    # Title escaped, not raw.
    assert body =~ "Feed Post &lt;One&gt; &amp; Co"
    refute body =~ "Feed Post <One>"
    assert body =~ ~s(<guid isPermaLink="true">)
    assert body =~ "/#{slug}/feed-post-one</guid>"
    assert body =~ ~s(rel="self")
  end

  test "unpublished posts are absent", %{conn: conn, group_slug: slug} do
    {:ok, _draft} =
      Posts.create_post(slug, %{
        title: "Draft Only",
        slug: "draft-only",
        content: "Not published."
      })

    body = get(conn, "/#{slug}/feed.xml") |> response(200)
    refute body =~ "Draft Only"
    assert body =~ "Feed Post"
  end

  test "404 for an unknown group — never the smart-fallback redirect", %{conn: conn} do
    conn = get(conn, "/no-such-group/feed.xml")
    assert conn.status == 404
  end

  test "404 when feeds are disabled", %{conn: conn, group_slug: slug} do
    {:ok, _} = Settings.update_boolean_setting("publishing_feeds_enabled", false)
    conn = get(conn, "/#{slug}/feed.xml")
    assert conn.status == 404
  end

  test "the listing page carries the feed autodiscovery link", %{conn: conn, group_slug: slug} do
    html = get(conn, "/" <> slug) |> html_response(200)
    assert html =~ ~s(type="application/rss+xml")
    assert html =~ "/#{slug}/feed.xml"
  end

  test "feed.xml can never be a post slug (reserved segment)", %{conn: conn, group_slug: slug} do
    # A post whose slug would collide is unreachable via the URL — the feed
    # branch wins. This pins the reservation rather than the (separately
    # validated) slug rules.
    conn = get(conn, "/#{slug}/feed.xml")
    assert rss_content_type(conn) =~ "application/rss+xml"
  end

  defp rss_content_type(conn) do
    conn |> Plug.Conn.get_resp_header("content-type") |> List.first() || ""
  end
end
