defmodule PhoenixKit.Integration.Publishing.ResolveLanguageToDialectTest do
  @moduledoc """
  Pins the resolution behavior of `Posts.read_post_by_uuid/3` when the
  caller passes a base language code (e.g. "en") instead of the full
  BCP-47 dialect ("en-GB"). The Listing builds the editor's default
  click-through URL with the base code, and the resolver must map it to
  whichever enabled dialect actually exists — not to the hard-coded
  `DialectMapper` default (which would resolve "en" → "en-US" even when
  only "en-GB" is enabled). See issue #11.
  """

  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.Posts
  alias PhoenixKit.Settings

  describe "read_post_by_uuid/3 with a base language code" do
    test "resolves to the only enabled dialect for that base when DialectMapper's default is not enabled" do
      configure_languages([
        {"en-GB", true},
        {"ru", false}
      ])

      {:ok, _} = Settings.update_setting("content_language", "en-GB")

      {:ok, group} = Groups.add_group(unique_name(), mode: "slug")

      {:ok, post} =
        Posts.create_post(group["slug"], %{title: "British Title", slug: "issue-11-post"})

      {:ok, saved} =
        Publishing.update_post(group["slug"], post, %{
          "title" => "British Title",
          "content" => "British body",
          "status" => "draft"
        })

      {:ok, _} = Publishing.add_language_to_post(group["slug"], saved[:uuid], "ru", 1)

      assert {:ok, fetched} = Publishing.read_post_by_uuid(saved[:uuid], "en", 1)
      assert fetched.language == "en-GB"
      assert fetched.metadata.title == "British Title"
      assert fetched.content == "British body"
    end

    test "prefers the primary dialect when multiple dialects share the base" do
      configure_languages([
        {"en-GB", false},
        {"en-US", true}
      ])

      {:ok, _} = Settings.update_setting("content_language", "en-US")

      {:ok, group} = Groups.add_group(unique_name(), mode: "slug")
      {:ok, post} = Posts.create_post(group["slug"], %{title: "American Title", slug: "ambig"})

      {:ok, saved} =
        Publishing.update_post(group["slug"], post, %{
          "title" => "American Title",
          "content" => "American body",
          "status" => "draft"
        })

      {:ok, _} = Publishing.add_language_to_post(group["slug"], saved[:uuid], "en-GB", 1)

      assert {:ok, fetched} = Publishing.read_post_by_uuid(saved[:uuid], "en", 1)
      assert fetched.language == "en-US"
      assert fetched.metadata.title == "American Title"
    end

    test "falls back to DialectMapper's default when no enabled dialect matches the base" do
      configure_languages([
        {"de-DE", true}
      ])

      {:ok, _} = Settings.update_setting("content_language", "de-DE")

      {:ok, group} = Groups.add_group(unique_name(), mode: "slug")
      {:ok, post} = Posts.create_post(group["slug"], %{title: "Deutscher Titel", slug: "de-only"})

      {:ok, saved} =
        Publishing.update_post(group["slug"], post, %{
          "title" => "Deutscher Titel",
          "content" => "Deutscher Text",
          "status" => "draft"
        })

      assert {:ok, fetched} = Publishing.read_post_by_uuid(saved[:uuid], "en", 1)
      assert fetched.language == "de-DE"
    end

    test "leaves the language unchanged when it is itself an enabled dialect" do
      configure_languages([
        {"en-GB", true},
        {"ru", false}
      ])

      {:ok, _} = Settings.update_setting("content_language", "en-GB")

      {:ok, group} = Groups.add_group(unique_name(), mode: "slug")
      {:ok, post} = Posts.create_post(group["slug"], %{title: "Title", slug: "direct"})

      {:ok, saved} =
        Publishing.update_post(group["slug"], post, %{
          "title" => "Title",
          "content" => "Body",
          "status" => "draft"
        })

      {:ok, _} = Publishing.add_language_to_post(group["slug"], saved[:uuid], "ru", 1)

      assert {:ok, fetched} = Publishing.read_post_by_uuid(saved[:uuid], "en-GB", 1)
      assert fetched.language == "en-GB"

      assert {:ok, ru} = Publishing.read_post_by_uuid(saved[:uuid], "ru", 1)
      assert ru.language == "ru"
    end

    test "resolves base to first match when the primary language is for a different base" do
      configure_languages([
        {"en-GB", false},
        {"en-US", false},
        {"fr-FR", true}
      ])

      {:ok, _} = Settings.update_setting("content_language", "fr-FR")

      {:ok, group} = Groups.add_group(unique_name(), mode: "slug")
      {:ok, post} = Posts.create_post(group["slug"], %{title: "T", slug: "tie-break-fallback"})

      {:ok, saved} =
        Publishing.update_post(group["slug"], post, %{
          "title" => "Titre",
          "content" => "Corps",
          "status" => "draft"
        })

      {:ok, _} = Publishing.add_language_to_post(group["slug"], saved[:uuid], "en-GB", 1)
      {:ok, _} = Publishing.add_language_to_post(group["slug"], saved[:uuid], "en-US", 1)

      # Primary "fr-FR" is not an English dialect, so the helper falls back to
      # the first enabled dialect with base "en" — which is "en-GB" (declaration
      # order in `languages_config`).
      assert {:ok, fetched} = Publishing.read_post_by_uuid(saved[:uuid], "en", 1)
      assert fetched.language == "en-GB"
    end

    test "passes a full dialect through unchanged when it is not enabled" do
      configure_languages([
        {"en-GB", true},
        {"ru", false}
      ])

      {:ok, _} = Settings.update_setting("content_language", "en-GB")

      {:ok, group} = Groups.add_group(unique_name(), mode: "slug")
      {:ok, post} = Posts.create_post(group["slug"], %{title: "T", slug: "passthrough"})

      {:ok, saved} =
        Publishing.update_post(group["slug"], post, %{
          "title" => "British Title",
          "content" => "British body",
          "status" => "draft"
        })

      # "en-US" is not enabled and is not a base code. The resolver returns it
      # unchanged; DBStorage's resolve_content/2 fallback then matches the
      # site default ("en-GB") and returns that content. This preserves
      # backwards compatibility for any caller that hands in a full code
      # without consulting the enabled list first.
      assert {:ok, fetched} = Publishing.read_post_by_uuid(saved[:uuid], "en-US", 1)
      assert fetched.language == "en-GB"
      assert fetched.metadata.title == "British Title"
    end

    test "returns nil for a nil language input" do
      configure_languages([{"en-GB", true}])
      {:ok, _} = Settings.update_setting("content_language", "en-GB")

      {:ok, group} = Groups.add_group(unique_name(), mode: "slug")
      {:ok, post} = Posts.create_post(group["slug"], %{title: "T", slug: "nil-input"})

      {:ok, saved} =
        Publishing.update_post(group["slug"], post, %{
          "title" => "British Title",
          "content" => "Body",
          "status" => "draft"
        })

      # nil → DBStorage.resolve_content/2 picks the site default. Pinning the
      # nil clause prevents accidental "if language do ..." regressions.
      assert {:ok, fetched} = Publishing.read_post_by_uuid(saved[:uuid], nil, 1)
      assert fetched.language == "en-GB"
    end
  end

  defp configure_languages(codes_with_default) do
    {:ok, _} = Settings.update_boolean_setting("languages_enabled", true)

    languages =
      codes_with_default
      |> Enum.with_index()
      |> Enum.map(fn {{code, is_default}, idx} ->
        %{
          "code" => code,
          "name" => code,
          "is_default" => is_default,
          "is_enabled" => true,
          "position" => idx
        }
      end)

    {:ok, _} = Settings.update_json_setting("languages_config", %{"languages" => languages})
    :ok
  end

  defp unique_name, do: "Issue11 #{System.unique_integer([:positive])}"
end
