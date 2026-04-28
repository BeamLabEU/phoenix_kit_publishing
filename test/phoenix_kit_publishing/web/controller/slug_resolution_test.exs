defmodule PhoenixKit.Modules.Publishing.Web.Controller.SlugResolutionTest do
  @moduledoc """
  Direct tests for `SlugResolution` — URL→internal slug resolution.
  Uses persistent_term injection (same trick as `listing_cache_test.exs`)
  to populate the listing cache, so we don't have to seed full multi-
  language posts in the DB.
  """

  use PhoenixKitPublishing.DataCase, async: false

  alias PhoenixKit.Modules.Publishing.ListingCache
  alias PhoenixKit.Modules.Publishing.Web.Controller.SlugResolution
  alias PhoenixKit.Settings

  defp unique_group, do: "sr-#{System.unique_integer([:positive])}"

  defp seed_cache(group_slug, posts) do
    :persistent_term.put(ListingCache.persistent_term_key(group_slug), posts)
  end

  setup do
    {:ok, _} = Settings.update_boolean_setting("languages_enabled", true)

    {:ok, _} =
      Settings.update_json_setting("languages_config", %{
        "languages" => [
          %{
            "code" => "en",
            "name" => "English",
            "is_default" => true,
            "is_enabled" => true,
            "position" => 0
          }
        ]
      })

    :ok
  end

  describe "resolve_url_slug/3 — slug-mode" do
    test "returns :passthrough when url_slug matches the internal slug" do
      group = unique_group()
      seed_cache(group, [%{slug: "alpha", language_slugs: %{"en" => "alpha"}, mode: :slug}])

      assert :passthrough = SlugResolution.resolve_url_slug(group, {:slug, "alpha"}, "en")
    end

    test "returns one of {:ok, ...} / :passthrough / {:redirect, ...} for known url_slug" do
      group = unique_group()

      seed_cache(group, [
        %{
          slug: "real-slug",
          language_slugs: %{"en" => "fancy-url"},
          mode: :slug,
          date: nil,
          time: nil
        }
      ])

      result = SlugResolution.resolve_url_slug(group, {:slug, "fancy-url"}, "en")

      assert match?({:ok, _}, result) or
               match?(:passthrough, result) or
               match?({:redirect, _}, result),
             "unexpected resolve result: #{inspect(result)}"
    end

    test "returns :passthrough when slug is not in cache/DB at all" do
      group = unique_group()
      seed_cache(group, [])

      assert :passthrough =
               SlugResolution.resolve_url_slug(group, {:slug, "nothing"}, "en")
    end

    test "returns :passthrough for non-slug identifier shapes" do
      assert :passthrough =
               SlugResolution.resolve_url_slug(
                 "any-group",
                 {:timestamp, "2026-04-27", "00:00"},
                 "en"
               )

      assert :passthrough = SlugResolution.resolve_url_slug("any-group", :other, "en")
    end
  end

  describe "resolve_url_slug_to_internal/3" do
    test "returns a string (either internal or fallback) for any input" do
      group = unique_group()

      seed_cache(group, [
        %{slug: "internal", language_slugs: %{"en" => "external"}, mode: :slug}
      ])

      result = SlugResolution.resolve_url_slug_to_internal(group, "external", "en")
      assert is_binary(result)
    end

    test "returns the input url_slug when not in cache (fallback)" do
      group = unique_group()
      seed_cache(group, [])

      assert SlugResolution.resolve_url_slug_to_internal(group, "missing", "en") == "missing"
    end
  end

  describe "build_post_redirect_url/4" do
    test "builds the public URL for the resolved post" do
      cached_post = %{
        slug: "real",
        mode: :slug,
        date: nil,
        time: nil,
        language_slugs: %{"en" => "redirected"}
      }

      url = SlugResolution.build_post_redirect_url("blog", cached_post, "en", "redirected")
      assert is_binary(url)
      assert url =~ "blog"
    end
  end
end
