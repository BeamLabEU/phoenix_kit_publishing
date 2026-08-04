defmodule PhoenixKit.Modules.Publishing.Web.Controller.SiblingDialectUrlsTest do
  @moduledoc """
  Pins the sibling-dialect URL model (2026-08, four-AI design consensus):

  - the base's OWNER dialect (primary-preferred) keeps the historical base
    URL (`/en/…` serves en-US) — zero change for existing sites;
  - a NON-owner sibling gets lowercase full-code URLs (`/en-gb/…`), the only
    shape that can address it; the switcher's two entries finally differ;
  - a sibling URL never bleeds the other sibling's content: it matches its
    own rows (or a literal legacy base row), else the post drops out;
  - `default_language_no_prefix` never strips the sibling's prefix.

  NOTE: in production these URLs additionally require core's locale plug to
  accept enabled dialect prefixes (it currently 301s every hyphenated
  segment to its base) — the paired core change. This suite exercises
  publishing's own routing/building/matching, which the test router reaches
  directly.
  """

  # async: false — mutates the global publishing + language settings rows.
  use PhoenixKitPublishing.ConnCase, async: false

  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.LanguageHelpers
  alias PhoenixKit.Modules.Publishing.Posts
  alias PhoenixKit.Modules.Publishing.TranslationManager
  alias PhoenixKit.Modules.Publishing.Versions
  alias PhoenixKit.Modules.Publishing.Web.HTML, as: PublishingHTML
  alias PhoenixKit.Settings

  defp unique_name(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  setup do
    {:ok, _} = Settings.update_boolean_setting("publishing_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("publishing_public_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("languages_enabled", true)
    {:ok, _} = Settings.update_setting("content_language", "en-US")

    {:ok, _} =
      Settings.update_json_setting("languages_config", %{
        "languages" => [
          %{
            "code" => "en-US",
            "name" => "English (US)",
            "is_default" => true,
            "is_enabled" => true,
            "position" => 0
          },
          %{
            "code" => "en-GB",
            "name" => "English (UK)",
            "is_default" => false,
            "is_enabled" => true,
            "position" => 1
          }
        ]
      })

    {:ok, group} = Groups.add_group(unique_name("dialects"), mode: "slug")
    slug = group["slug"]

    {:ok, post} =
      Posts.create_post(slug, %{
        title: "Color Story",
        slug: "color-story",
        content: "The US body about color.\n\nMore."
      })

    {:ok, _} = TranslationManager.add_language_to_post(slug, post.uuid, "en-GB", nil)
    {:ok, gb_read} = Posts.read_post_by_uuid(post.uuid, "en-GB", 1)

    {:ok, _} =
      Posts.update_post(
        slug,
        gb_read,
        %{
          "title" => "Colour Story",
          "content" => "The UK body about colour.\n\nMore.",
          "url_slug" => "colour-story"
        },
        %{}
      )

    :ok = Versions.publish_version(slug, post.uuid, 1)

    %{group_slug: slug, post: post}
  end

  describe "public_url_segment/1" do
    test "owner keeps the base, sibling gets the lowercase full code" do
      assert LanguageHelpers.public_url_segment("en-US") == "en"
      assert LanguageHelpers.public_url_segment("en") == "en"
      assert LanguageHelpers.public_url_segment("en-GB") == "en-gb"
      assert LanguageHelpers.public_url_segment("en-gb") == "en-gb"
      # single-dialect bases are untouched
      assert LanguageHelpers.public_url_segment("de-DE") == "de"
      assert LanguageHelpers.public_url_segment(nil) == "en"
    end
  end

  describe "URL building" do
    test "the two switcher entries carry DIFFERENT URLs", %{conn: conn, group_slug: slug} do
      body = conn |> get("/en/#{slug}") |> html_response(200)

      assert body =~ ~s(href="/en-gb/#{slug}")
      assert body =~ ~s(href="/en/#{slug}")
    end

    test "sibling listing cards link the sibling's slug under the sibling prefix", %{
      conn: conn,
      group_slug: slug
    } do
      body = conn |> get("/en-gb/#{slug}") |> html_response(200)

      assert body =~ "Colour Story"
      assert body =~ ~s(href="/en-gb/#{slug}/colour-story")
      refute body =~ "The US body"
    end
  end

  describe "resolution" do
    test "/en/ serves the owner (primary) dialect", %{conn: conn, group_slug: slug} do
      body = conn |> get("/en/#{slug}") |> html_response(200)

      assert body =~ "Color Story"
      refute body =~ "Colour Story"
    end

    test "the sibling's custom slug resolves under its prefix", %{conn: conn, group_slug: slug} do
      conn = get(conn, "/en-gb/#{slug}/colour-story")

      body =
        case conn.status do
          200 ->
            html_response(conn, 200)

          status when status in [301, 302] ->
            location = get_resp_header(conn, "location") |> List.first()
            assert location =~ "colour-story"
            build_conn() |> get(location) |> html_response(200)
        end

      assert body =~ "The UK body about colour."
      refute body =~ "The US body"
    end

    test "a post without the sibling's translation drops off the sibling listing", %{
      conn: conn,
      group_slug: slug
    } do
      {:ok, us_only} =
        Posts.create_post(slug, %{title: "US Only", slug: "us-only", content: "US only body."})

      :ok = Versions.publish_version(slug, us_only.uuid, 1)

      body = conn |> get("/en-gb/#{slug}") |> html_response(200)
      refute body =~ "US Only"

      en_body = build_conn() |> get("/en/#{slug}") |> html_response(200)
      assert en_body =~ "US Only"
    end
  end

  describe "default_language_no_prefix" do
    test "strips only the primary's prefix, never the sibling's", %{group_slug: slug} do
      {:ok, _} = Settings.update_boolean_setting("default_language_no_prefix", true)

      on_exit(fn ->
        {:ok, _} = Settings.update_boolean_setting("default_language_no_prefix", false)
      end)

      assert PublishingHTML.group_listing_path("en-US", slug) == "/#{slug}"
      assert PublishingHTML.group_listing_path("en-GB", slug) == "/en-gb/#{slug}"
    end
  end
end
