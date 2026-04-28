defmodule PhoenixKit.Modules.Publishing.Web.HTMLHelpersTest do
  @moduledoc """
  Pure-function tests for the formatting / URL / pluralisation helpers
  in `Web.HTML`. These never reach the DB and don't render HEEx — they
  cover the building blocks called by the public LiveView pages.
  """

  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Publishing.Web.HTML

  describe "format_date/1" do
    test "formats a DateTime to 'Month dd, YYYY'" do
      dt = ~U[2026-04-27 12:00:00Z]
      assert HTML.format_date(dt) == "April 27, 2026"
    end

    test "formats an ISO 8601 string the same way" do
      assert HTML.format_date("2026-04-27T12:00:00Z") == "April 27, 2026"
    end

    test "returns the original string when the binary isn't ISO 8601" do
      assert HTML.format_date("not-a-date") == "not-a-date"
    end

    test "returns empty string for nil / unrelated input" do
      assert HTML.format_date(nil) == ""
      assert HTML.format_date(:atom) == ""
      assert HTML.format_date(42) == ""
    end
  end

  describe "format_date_with_time/1" do
    test "formats a DateTime with 'date at HH:MM'" do
      dt = ~U[2026-04-27 14:30:00Z]
      result = HTML.format_date_with_time(dt)
      assert result =~ "April 27, 2026"
      assert result =~ "14:30"
    end

    test "parses ISO string and renders date-with-time" do
      result = HTML.format_date_with_time("2026-04-27T14:30:00Z")
      assert result =~ "April 27, 2026"
      assert result =~ "14:30"
    end

    test "returns the original string when binary isn't ISO 8601" do
      assert HTML.format_date_with_time("not-iso") == "not-iso"
    end

    test "returns empty string for nil" do
      assert HTML.format_date_with_time(nil) == ""
    end
  end

  describe "format_date_for_url/1" do
    test "formats DateTime to YYYY-MM-DD" do
      assert HTML.format_date_for_url(~U[2026-04-27 12:00:00Z]) == "2026-04-27"
    end

    test "formats ISO string to YYYY-MM-DD" do
      assert HTML.format_date_for_url("2026-04-27T00:00:00Z") == "2026-04-27"
    end

    test "returns fallback for invalid binary" do
      assert HTML.format_date_for_url("nope") == "2025-01-01"
    end

    test "returns fallback for nil" do
      assert HTML.format_date_for_url(nil) == "2025-01-01"
    end
  end

  describe "format_time_for_url/1" do
    test "formats DateTime to HH:MM" do
      assert HTML.format_time_for_url(~U[2026-04-27 14:30:45Z]) == "14:30"
    end

    test "formats ISO string to HH:MM" do
      assert HTML.format_time_for_url("2026-04-27T09:05:00Z") == "09:05"
    end

    test "returns fallback for invalid binary" do
      assert HTML.format_time_for_url("nope") == "00:00"
    end

    test "returns fallback for nil" do
      assert HTML.format_time_for_url(nil) == "00:00"
    end
  end

  describe "pluralize/3" do
    test "uses singular for count 1" do
      assert HTML.pluralize(1, "post", "posts") == "1 post"
    end

    test "uses plural for 0" do
      assert HTML.pluralize(0, "post", "posts") == "0 posts"
    end

    test "uses plural for >1" do
      assert HTML.pluralize(5, "post", "posts") == "5 posts"
    end
  end

  describe "extract_excerpt/1" do
    test "returns content before <!-- more --> when the marker exists" do
      content = "Lead paragraph.\n\n<!-- more -->\nMore content here."
      assert HTML.extract_excerpt(content) =~ "Lead paragraph"
      refute HTML.extract_excerpt(content) =~ "More content"
    end

    test "returns first paragraph when no <!-- more --> marker" do
      content = "First para.\n\nSecond para."
      assert HTML.extract_excerpt(content) =~ "First para"
      refute HTML.extract_excerpt(content) =~ "Second para"
    end

    test "returns empty string for non-binary input" do
      assert HTML.extract_excerpt(nil) == ""
      assert HTML.extract_excerpt(123) == ""
    end
  end

  describe "has_publication_date?/1" do
    test "returns true for a timestamp-mode post with a date" do
      assert HTML.has_publication_date?(%{mode: :timestamp, date: ~D[2026-04-27]})
    end

    test "returns false for a timestamp-mode post without a date" do
      refute HTML.has_publication_date?(%{mode: :timestamp, date: nil})
    end

    test "returns true for a slug-mode post with metadata.published_at" do
      assert HTML.has_publication_date?(%{
               mode: :slug,
               metadata: %{published_at: "2026-04-27T00:00:00Z"}
             })
    end

    test "returns false for a slug-mode post with empty published_at" do
      refute HTML.has_publication_date?(%{mode: :slug, metadata: %{published_at: ""}})
    end

    test "returns false for a slug-mode post with no metadata" do
      refute HTML.has_publication_date?(%{mode: :slug, metadata: %{}})
    end
  end

  describe "build_date_counts/1" do
    test "returns frequency map of timestamp-mode post dates as iso8601 strings" do
      posts = [
        %{mode: :timestamp, date: ~D[2026-04-27], time: ~T[10:00:00]},
        %{mode: :timestamp, date: ~D[2026-04-27], time: ~T[14:00:00]},
        %{mode: :timestamp, date: ~D[2026-04-28], time: ~T[10:00:00]},
        %{
          mode: :slug,
          date: nil,
          time: nil,
          metadata: %{published_at: "2026-05-01T00:00:00Z"}
        }
      ]

      counts = HTML.build_date_counts(posts)
      assert counts["2026-04-27"] == 2
      assert counts["2026-04-28"] == 1
      # slug-mode posts are filtered out, not counted
      assert Map.keys(counts) |> Enum.sort() == ["2026-04-27", "2026-04-28"]
    end

    test "returns empty map for empty input" do
      assert HTML.build_date_counts([]) == %{}
    end
  end

  describe "featured_image_url/2" do
    test "returns nil when post has no featured_image_uuid" do
      post = %{metadata: %{featured_image_uuid: nil}}
      assert HTML.featured_image_url(post) == nil
    end

    test "returns nil when featured_image_uuid is empty string" do
      post = %{metadata: %{featured_image_uuid: ""}}
      assert HTML.featured_image_url(post) == nil
    end
  end

  describe "build_public_translations/2" do
    test "maps translations to language-switcher format" do
      translations = [
        %{
          code: "en",
          display_code: "EN",
          name: "English",
          flag: "🇬🇧",
          url: "/en/blog/x",
          current: true
        },
        %{
          code: "fr",
          display_code: nil,
          name: "French",
          flag: nil,
          url: "/fr/blog/x",
          current: false
        }
      ]

      result = HTML.build_public_translations(translations, "en")

      assert length(result) == 2
      en = Enum.find(result, &(&1.code == "en"))
      fr = Enum.find(result, &(&1.code == "fr"))
      assert en.current == true
      assert en.exists == true
      assert en.status == "published"
      assert fr.display_code == "fr"
      assert fr.flag == ""
      assert fr.current == false
    end

    test "returns empty list for empty input" do
      assert HTML.build_public_translations([], "en") == []
    end
  end

  describe "public_current_language/2" do
    test "returns the code of the current translation" do
      translations = [
        %{code: "en", current: false},
        %{code: "fr", current: true}
      ]

      assert HTML.public_current_language(translations, "en") == "fr"
    end

    test "returns fallback when no translation is current" do
      translations = [%{code: "en", current: false}]
      assert HTML.public_current_language(translations, "default") == "default"
    end

    test "returns fallback for empty list" do
      assert HTML.public_current_language([], "fallback") == "fallback"
    end
  end
end
