defmodule PhoenixKit.Modules.Publishing.LanguageHelpersTest do
  use PhoenixKitPublishing.DataCase, async: true

  alias PhoenixKit.Modules.Publishing.LanguageHelpers
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

  describe "url_language_code/1" do
    test "shortens full locale codes to their base code for public URLs" do
      assert LanguageHelpers.url_language_code("en-GB") == "en"
      assert LanguageHelpers.url_language_code("de-DE") == "de"
      assert LanguageHelpers.url_language_code("pt-BR") == "pt"
    end

    test "keeps base language codes unchanged" do
      assert LanguageHelpers.url_language_code("en") == "en"
      assert LanguageHelpers.url_language_code("de") == "de"
    end

    test "allows nil for optional URL language inputs" do
      assert LanguageHelpers.url_language_code(nil) == nil
    end
  end

  describe "get_primary_language_base/0" do
    test "returns an unqualified base language code" do
      result = LanguageHelpers.get_primary_language_base()

      assert is_binary(result)
      refute String.contains?(result, "-")
    end
  end

  describe "default_language_no_prefix?/0" do
    test "defaults to false" do
      refute LanguageHelpers.default_language_no_prefix?()
    end

    test "reads the stored setting" do
      {:ok, _} = Settings.update_boolean_setting("publishing_default_language_no_prefix", true)
      assert LanguageHelpers.default_language_no_prefix?()
    end
  end

  describe "use_language_prefix?/1" do
    test "keeps prefix for the default language when the setting is off" do
      assert LanguageHelpers.use_language_prefix?("en")
    end

    test "omits prefix for the default language when the setting is on" do
      {:ok, _} = Settings.update_boolean_setting("publishing_default_language_no_prefix", true)
      refute LanguageHelpers.use_language_prefix?("en")
    end

    test "keeps prefix for non-default languages when the setting is on" do
      {:ok, _} = Settings.update_boolean_setting("publishing_default_language_no_prefix", true)
      assert LanguageHelpers.use_language_prefix?("de")
    end
  end
end
