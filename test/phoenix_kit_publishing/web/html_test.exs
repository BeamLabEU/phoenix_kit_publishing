defmodule PhoenixKit.Modules.Publishing.Web.HTMLTest do
  use PhoenixKitPublishing.DataCase, async: true

  alias PhoenixKit.Modules.Publishing.Web.HTML, as: PublishingHTML
  alias PhoenixKit.Settings

  setup do
    {:ok, _} = Settings.update_boolean_setting("languages_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("publishing_default_language_no_prefix", false)

    {:ok, _} =
      Settings.update_json_setting("languages_config", %{
        "languages" => [
          %{
            "code" => "en-GB",
            "name" => "English (United Kingdom)",
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

    :ok
  end

  describe "group_listing_path/3" do
    test "normalizes a full locale code to its base code" do
      url = PublishingHTML.group_listing_path("en-GB", "blog")

      assert url =~ ~r{/en/blog$}
      refute url =~ "/en-GB/"
    end

    test "omits the prefix for the default language when configured" do
      {:ok, _} = Settings.update_boolean_setting("publishing_default_language_no_prefix", true)

      assert PublishingHTML.group_listing_path("en-GB", "blog") =~ ~r{/blog$}
      refute PublishingHTML.group_listing_path("en-GB", "blog") =~ "/en/blog"
    end

    test "keeps prefixes for non-default languages when default is prefixless" do
      {:ok, _} = Settings.update_boolean_setting("publishing_default_language_no_prefix", true)

      assert PublishingHTML.group_listing_path("de-DE", "blog") =~ ~r{/de/blog$}
    end
  end

  describe "build_post_url/4" do
    test "normalizes a full locale code to its base code" do
      post = %{mode: :slug, slug: "my-post", metadata: %{}, language_slugs: %{}}
      url = PublishingHTML.build_post_url("blog", post, "en-GB")

      assert url =~ ~r{/en/blog/my-post$}
      refute url =~ "/en-GB/"
    end

    test "falls back to en when language is nil" do
      post = %{mode: :slug, slug: "my-post", metadata: %{}, language_slugs: %{}}

      assert PublishingHTML.build_post_url("blog", post, nil) =~ ~r{/en/blog/my-post$}
    end

    test "omits the prefix for default-language post URLs when configured" do
      {:ok, _} = Settings.update_boolean_setting("publishing_default_language_no_prefix", true)
      post = %{mode: :slug, slug: "my-post", metadata: %{}, language_slugs: %{}}

      assert PublishingHTML.build_post_url("blog", post, "en-GB") =~ ~r{/blog/my-post$}
      refute PublishingHTML.build_post_url("blog", post, "en-GB") =~ "/en/blog"
    end
  end

  describe "build_public_path_with_time/4" do
    test "normalizes a full locale code to its base code" do
      url = PublishingHTML.build_public_path_with_time("de-DE", "blog", "2026-04-23", "19:30")

      assert url =~ ~r{/de/blog/2026-04-23/19:30$}
      refute url =~ "/de-DE/"
    end

    test "omits the prefix for default-language timestamp URLs when configured" do
      {:ok, _} = Settings.update_boolean_setting("publishing_default_language_no_prefix", true)

      url = PublishingHTML.build_public_path_with_time("en-GB", "blog", "2026-04-23", "19:30")

      assert url =~ ~r{/blog/2026-04-23/19:30$}
      refute url =~ "/en/blog"
    end
  end
end
