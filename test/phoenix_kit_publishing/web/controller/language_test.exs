defmodule PhoenixKit.Modules.Publishing.Web.Controller.LanguageTest do
  use PhoenixKitPublishing.DataCase, async: true

  alias PhoenixKit.Modules.Publishing.Web.Controller.Language
  alias PhoenixKit.Settings

  setup do
    {:ok, _} = Settings.update_boolean_setting("languages_enabled", true)

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

    {:ok, _} = Settings.update_boolean_setting("publishing_default_language_no_prefix", false)
    :ok
  end

  describe "request_matches_canonical_url?/2" do
    test "matches request path and query string" do
      conn = Plug.Test.conn(:get, "/en/blog?page=2")

      assert Language.request_matches_canonical_url?(conn, "/en/blog?page=2")
      refute Language.request_matches_canonical_url?(conn, "/en/blog")
    end
  end

  describe "prefixed_default_language_request?/2" do
    test "detects prefixed requests for the default language when enabled" do
      {:ok, _} = Settings.update_boolean_setting("publishing_default_language_no_prefix", true)

      conn =
        Plug.Test.conn(:get, "/en/blog")
        |> Map.put(:params, %{"language" => "en", "group" => "blog"})

      assert Language.prefixed_default_language_request?(conn, "en")
    end

    test "ignores non-default languages" do
      {:ok, _} = Settings.update_boolean_setting("publishing_default_language_no_prefix", true)

      conn =
        Plug.Test.conn(:get, "/de/blog")
        |> Map.put(:params, %{"language" => "de", "group" => "blog"})

      refute Language.prefixed_default_language_request?(conn, "de")
    end
  end

  describe "get_default_language/0" do
    test "prefers the publishing primary language over the frontend languages default" do
      assert Language.get_default_language() ==
               PhoenixKit.Modules.Publishing.get_primary_language()
    end
  end
end
