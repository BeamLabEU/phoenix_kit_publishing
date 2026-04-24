defmodule PhoenixKit.Integration.Publishing.StaleFixerTest do
  use PhoenixKit.DataCase, async: true

  alias PhoenixKit.Modules.Publishing.DBStorage
  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.Posts
  alias PhoenixKit.Modules.Publishing.StaleFixer
  alias PhoenixKit.Settings

  defp unique_name, do: "stale-fixer-group-#{System.unique_integer([:positive])}"

  setup do
    {:ok, _} = Settings.update_boolean_setting("languages_enabled", true)

    {:ok, _} =
      Settings.update_json_setting("languages_config", %{
        "languages" => [
          %{
            "code" => "en-US",
            "name" => "English (United States)",
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

  test "normalizes legacy base-language content to the enabled dialect" do
    {:ok, _} = Settings.update_setting("content_language", "en")
    {:ok, group} = Groups.add_group(unique_name(), mode: "slug")
    {:ok, post} = Posts.create_post(group["slug"], %{title: "Legacy English"})

    [version] = DBStorage.list_versions(post.uuid)
    [content] = DBStorage.list_contents(version.uuid)

    {:ok, _} = Settings.update_setting("content_language", "en-US")

    StaleFixer.fix_stale_content(content)

    [normalized] = DBStorage.list_contents(version.uuid)
    assert normalized.language == "en-US"
  end

  test "removes duplicate legacy base-language content when dialect content already exists" do
    {:ok, _} = Settings.update_setting("content_language", "en-US")
    {:ok, group} = Groups.add_group(unique_name(), mode: "slug")
    {:ok, post} = Posts.create_post(group["slug"], %{title: "Dialect English"})

    [version] = DBStorage.list_versions(post.uuid)

    {:ok, legacy} =
      DBStorage.create_content(%{
        version_uuid: version.uuid,
        language: "en",
        title: "Legacy English",
        content: "Legacy body",
        status: "published",
        url_slug: "legacy-english",
        data: %{"previous_url_slugs" => ["older-legacy"]}
      })

    StaleFixer.fix_stale_content(legacy)

    contents = DBStorage.list_contents(version.uuid)

    assert Enum.map(contents, & &1.language) == ["en-US"]
    refute Enum.any?(contents, &(&1.uuid == legacy.uuid))
  end

  test "public post reads lazily normalize legacy base-language content" do
    {:ok, _} = Settings.update_setting("content_language", "en")
    {:ok, group} = Groups.add_group(unique_name(), mode: "slug")

    {:ok, post} =
      Posts.create_post(group["slug"], %{title: "Lazy Normalize", slug: "lazy-normalize"})

    {:ok, _} = Settings.update_setting("content_language", "en-US")

    assert {:ok, read_post} = Posts.read_post(group["slug"], "lazy-normalize", "en-US", nil)
    assert read_post.language == "en-US"

    [version] = DBStorage.list_versions(post.uuid)
    assert Enum.map(DBStorage.list_contents(version.uuid), & &1.language) == ["en-US"]
  end

  test "url slug lookup repairs legacy base-language slugs for the primary dialect" do
    {:ok, _} = Settings.update_setting("content_language", "en-US")
    {:ok, group} = Groups.add_group(unique_name(), mode: "slug")

    {:ok, post} =
      Posts.create_post(group["slug"], %{
        title: "Markdown Rendering Demo",
        slug: "markdown-rendering-demo"
      })

    [version] = DBStorage.list_versions(post.uuid)
    [content] = DBStorage.list_contents(version.uuid)

    {:ok, legacy_content} =
      DBStorage.update_content(content, %{language: "en", url_slug: "markdown-rendering-demo"})

    assert legacy_content.language == "en"
    assert legacy_content.url_slug == "markdown-rendering-demo"

    assert {:ok, resolved_post} =
             Posts.find_by_url_slug(group["slug"], "en-US", "markdown-rendering-demo")

    assert resolved_post.language == "en-US"

    [normalized] = DBStorage.list_contents(version.uuid)
    assert normalized.language == "en-US"
    assert normalized.url_slug == "markdown-rendering-demo"
  end

  test "normalization prefers the primary dialect when multiple dialects share the base" do
    {:ok, _} =
      Settings.update_json_setting("languages_config", %{
        "languages" => [
          %{
            "code" => "en-US",
            "name" => "English (United States)",
            "is_default" => true,
            "is_enabled" => true,
            "position" => 0
          },
          %{
            "code" => "en-GB",
            "name" => "English (United Kingdom)",
            "is_default" => false,
            "is_enabled" => true,
            "position" => 1
          }
        ]
      })

    {:ok, _} = Settings.update_setting("content_language", "en")
    {:ok, group} = Groups.add_group(unique_name(), mode: "slug")
    {:ok, post} = Posts.create_post(group["slug"], %{title: "Prefer Primary Dialect"})
    [version] = DBStorage.list_versions(post.uuid)
    [content] = DBStorage.list_contents(version.uuid)

    {:ok, _} = Settings.update_setting("content_language", "en-US")

    StaleFixer.fix_stale_content(content)

    [normalized] = DBStorage.list_contents(version.uuid)
    assert normalized.language == "en-US"
  end

  test "timestamp-mode post reads lazily normalize legacy base-language content" do
    {:ok, _} = Settings.update_setting("content_language", "en")
    {:ok, group} = Groups.add_group(unique_name(), mode: "timestamp")

    {:ok, post} = Posts.create_post(group["slug"], %{title: "Timestamp Normalize"})

    {:ok, _} = Settings.update_setting("content_language", "en-US")

    date_str = Date.to_iso8601(post.date)
    time_str = post.time |> Time.to_string() |> String.slice(0, 5)

    assert {:ok, read_post} =
             Posts.read_post(group["slug"], "#{date_str}/#{time_str}", "en-US", nil)

    assert read_post.language == "en-US"

    [version] = DBStorage.list_versions(post.uuid)
    assert Enum.map(DBStorage.list_contents(version.uuid), & &1.language) == ["en-US"]
  end
end
