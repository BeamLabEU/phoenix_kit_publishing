defmodule PhoenixKit.Modules.Publishing.Web.Controller.CanonicalSegmentRedirectTest do
  @moduledoc """
  Two canonical 301s that never fired, and the loop guards around them.

  A request whose LANGUAGE SEGMENT differs from the display segment must
  301 even when the resolved language is already the canonical one: with
  `en-US` owning `/en/` and `en-GB` enabled too, `/en-US/<group>/<post>`
  served 200 while every builder emits `/en/<group>/<post>`. Feeds only
  checked the prefixed-default case, so `/de-DE/<group>/feed.xml` served the
  feed instead of 301ing (feed-to-feed) onto `/de/<group>/feed.xml`.

  Each redirect is followed once and must land on a 200 — a canonical that
  bounces to itself is the loop the status test above this one pins.
  """

  # async: false — mutates the global publishing + language settings rows.
  use PhoenixKitPublishing.ConnCase, async: false

  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.Posts
  alias PhoenixKit.Modules.Publishing.Versions
  alias PhoenixKit.Settings

  defp unique_name(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp enable_languages(languages, primary) do
    {:ok, _} = Settings.update_boolean_setting("publishing_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("publishing_public_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("publishing_feeds_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("languages_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("default_language_no_prefix", false)
    {:ok, _} = Settings.update_setting("content_language", primary)

    {:ok, _} =
      Settings.update_json_setting("languages_config", %{
        "languages" =>
          languages
          |> Enum.with_index()
          |> Enum.map(fn {code, idx} ->
            %{
              "code" => code,
              "name" => code,
              "is_default" => code == primary,
              "is_enabled" => true,
              "position" => idx
            }
          end)
      })

    :ok
  end

  defp published_group do
    {:ok, group} = Groups.add_group(unique_name("segment"), mode: "slug")
    slug = group["slug"]

    {:ok, post} =
      Posts.create_post(slug, %{title: "Segment", slug: "segment", content: "English body."})

    :ok = Versions.publish_version(slug, post.uuid, 1)
    slug
  end

  # One hop: the 301's target must itself serve 200 — never redirect again.
  defp assert_301_then_200(conn, path, expected_location) do
    conn = get(conn, path)
    assert conn.status == 301, "#{path} answered #{conn.status}, expected 301"
    location = redirected_to(conn, 301)
    assert location == expected_location

    landed = build_conn() |> get(location)
    assert landed.status == 200, "#{location} answered #{landed.status}, expected 200"
    landed
  end

  describe "a language segment that is not the display segment" do
    setup do
      enable_languages(["en-US", "en-GB"], "en-US")
      %{group_slug: published_group()}
    end

    test "the post 301s from /en-US/ to the owner's /en/ segment", %{
      conn: conn,
      group_slug: slug
    } do
      assert_301_then_200(conn, "/en-US/#{slug}/segment", "/en/#{slug}/segment")
    end

    test "the listing 301s from /en-US/ to /en/", %{conn: conn, group_slug: slug} do
      assert_301_then_200(conn, "/en-US/#{slug}", "/en/#{slug}")
    end

    test "the query string rides along and the target does not loop", %{
      conn: conn,
      group_slug: slug
    } do
      assert_301_then_200(conn, "/en-US/#{slug}/segment?utm=x", "/en/#{slug}/segment?utm=x")
      assert_301_then_200(conn, "/en-US/#{slug}?utm=x", "/en/#{slug}?utm=x")
    end

    test "the canonical URLs themselves serve 200 with no redirect", %{
      conn: conn,
      group_slug: slug
    } do
      assert get(conn, "/en/#{slug}/segment").status == 200
      assert get(conn, "/en/#{slug}").status == 200
      assert get(conn, "/en/#{slug}?utm=x").status == 200
      assert get(conn, "/en/#{slug}/feed.xml").status == 200
    end
  end

  describe "feeds" do
    setup do
      enable_languages(["en", "de-DE"], "en")
      %{group_slug: published_group()}
    end

    test "/de-DE/…/feed.xml 301s feed-to-feed onto /de/…/feed.xml", %{
      conn: conn,
      group_slug: slug
    } do
      landed = assert_301_then_200(conn, "/de-DE/#{slug}/feed.xml", "/de/#{slug}/feed.xml")

      # Feed-to-feed: the target is the RSS document, never the HTML fallback.
      assert landed |> get_resp_header("content-type") |> List.first() =~ "application/rss+xml"
    end

    test "the canonical feed URLs serve 200 with no redirect", %{conn: conn, group_slug: slug} do
      assert get(conn, "/de/#{slug}/feed.xml").status == 200
      assert get(conn, "/en/#{slug}/feed.xml").status == 200
      assert get(conn, "/de/#{slug}/feed.xml?utm=x").status == 200
    end
  end
end
