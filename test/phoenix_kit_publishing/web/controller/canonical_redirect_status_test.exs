defmodule PhoenixKit.Modules.Publishing.Web.Controller.CanonicalRedirectStatusTest do
  @moduledoc """
  Two ways the canonical 301 fired where it must not.

  The loop: with a dialect primary ("en-US") and `default_language_no_prefix`
  on, the request language is the content language ("en-US") while the
  canonical language is its display code ("en"), so the code comparison
  always demanded a redirect and the URL comparison matched the request's
  full query string against a canonical that carries none — while the 301
  re-appends that query. Every prefixless request with a `?utm_source=`
  redirected to itself.

  The permanent fallback: `/et/<group>/<slug>` with no Estonian row read the
  fallback language's content, took its language as canonical and issued a
  cacheable 301 — a content state (the listing twin 302s with the
  "closest match" flash) frozen into a permanent redirect.
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
    {:ok, _} = Settings.update_boolean_setting("languages_enabled", true)
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

  defp with_no_prefix(fun) do
    {:ok, _} = Settings.update_boolean_setting("default_language_no_prefix", true)

    try do
      fun.()
    after
      {:ok, _} = Settings.update_boolean_setting("default_language_no_prefix", false)
    end
  end

  setup do
    enable_languages(["en-US", "et-EE"], "en-US")
    {:ok, _} = Settings.update_boolean_setting("default_language_no_prefix", false)

    {:ok, group} = Groups.add_group(unique_name("canon"), mode: "slug")
    slug = group["slug"]

    {:ok, post} =
      Posts.create_post(slug, %{title: "Canon", slug: "canon", content: "English body."})

    :ok = Versions.publish_version(slug, post.uuid, 1)

    %{group_slug: slug}
  end

  describe "prefixless dialect primary with a query string" do
    test "the listing renders instead of redirecting to itself", %{conn: conn, group_slug: slug} do
      with_no_prefix(fn ->
        conn = get(conn, "/#{slug}?utm_source=x")
        assert conn.status == 200
      end)
    end

    test "the post renders instead of redirecting to itself", %{conn: conn, group_slug: slug} do
      with_no_prefix(fn ->
        conn = get(conn, "/#{slug}/canon?x=1")
        assert conn.status == 200
      end)
    end

    test "an explicit default prefix still 301s, keeping the query", %{
      conn: conn,
      group_slug: slug
    } do
      with_no_prefix(fn ->
        conn = get(conn, "/en/#{slug}/canon?x=1")
        assert conn.status == 301
        assert redirected_to(conn, 301) == "/#{slug}/canon?x=1"
      end)
    end
  end

  describe "a translation the post does not have" do
    test "is a 302 with the closest-match flash, not a permanent redirect", %{
      conn: conn,
      group_slug: slug
    } do
      conn = get(conn, "/et/#{slug}/canon")

      assert conn.status == 302
      assert redirected_to(conn) =~ "/en/#{slug}/canon"

      # The request's locale is Estonian, so the flash is too.
      expected =
        Gettext.with_locale(PhoenixKitPublishing.Gettext, "et", fn ->
          Gettext.gettext(
            PhoenixKitPublishing.Gettext,
            "The page you requested was not found. Showing closest match."
          )
        end)

      assert Phoenix.Flash.get(conn.assigns.flash, :info) == expected
    end

    test "the display-code canonicalisation stays a 301", %{conn: conn, group_slug: slug} do
      # One English dialect enabled: its canonical segment is the base code.
      conn = get(conn, "/en-US/#{slug}/canon")

      assert conn.status == 301
      assert redirected_to(conn, 301) == "/en/#{slug}/canon"
    end
  end
end
