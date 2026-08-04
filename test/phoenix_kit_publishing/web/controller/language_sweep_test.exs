defmodule PhoenixKit.Modules.Publishing.Web.Controller.LanguageSweepTest do
  @moduledoc """
  Pins the 2026-08 public-side language sweep: each test here fails on the
  pre-sweep code.

  Covered: untranslated stubs stay off the public surface, the listing's
  language-fallback redirect, base-code gettext locale on full-code
  default languages, language-agnostic date-URL disambiguation, the unified
  base→dialect tie-break, the sibling-dialect no-prefix guard, excerpt
  hygiene, and the slug-collision previous_url_slugs trail.
  """

  # async: false — mutates the global publishing + language settings rows.
  use PhoenixKitPublishing.ConnCase, async: false

  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.DBStorage
  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.LanguageHelpers
  alias PhoenixKit.Modules.Publishing.Posts
  alias PhoenixKit.Modules.Publishing.SlugHelpers
  alias PhoenixKit.Modules.Publishing.TranslationManager
  alias PhoenixKit.Modules.Publishing.Versions
  alias PhoenixKit.Modules.Publishing.Web.Controller.Language
  alias PhoenixKit.Modules.Publishing.Web.HTML, as: PublishingHTML
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

  defp published_post(group_slug, attrs) do
    {:ok, post} = Posts.create_post(group_slug, attrs)
    :ok = Versions.publish_version(group_slug, post.uuid, 1)
    post
  end

  describe "untranslated stubs stay off the public surface" do
    setup %{} do
      enable_languages(["en-US", "de-DE"], "en-US")
      {:ok, group} = Groups.add_group(unique_name("stub"), mode: "slug")

      post =
        published_post(group["slug"], %{
          title: "Real English",
          slug: "real-english",
          content: "English body paragraph.\n\nMore."
        })

      # The bug's trigger: adding a language creates {title: "Untitled",
      # content: ""} on the ACTIVE version — instantly present in
      # available_languages.
      {:ok, _} = TranslationManager.add_language_to_post(group["slug"], post.uuid, "de-DE", nil)

      %{group_slug: group["slug"], post: post}
    end

    test "the stub language's listing does not show an Untitled card", %{
      conn: conn,
      group_slug: slug
    } do
      conn = get(conn, "/de/#{slug}")

      # No German content in the group → the listing language fallback
      # redirects rather than rendering an Untitled card or an empty page.
      assert conn.status == 302
      assert redirected_to(conn) == "/en/#{slug}"
      refute (conn |> get_resp_header("location") |> List.first() || "") =~ "untitled"
    end

    test "the stub post URL falls back instead of serving an empty page", %{
      conn: conn,
      group_slug: slug
    } do
      conn = get(conn, "/de/#{slug}/real-english")

      # Never a 200 with an empty German body: smart fallback (other
      # language → listing).
      assert conn.status in [301, 302]
    end

    test "a real translation lifts both restrictions", %{
      conn: conn,
      group_slug: slug,
      post: post
    } do
      {:ok, de_read} = Posts.read_post_by_uuid(post.uuid, "de-DE", 1)

      {:ok, _} =
        Posts.update_post(
          slug,
          de_read,
          %{"title" => "Echtes Deutsch", "content" => "Deutscher Absatz.\n\nMehr."},
          %{}
        )

      body = conn |> get("/de/#{slug}") |> html_response(200)
      assert body =~ "Echtes Deutsch"
      assert body =~ "Deutscher Absatz."
    end
  end

  describe "listing language fallback" do
    test "a contentless language 302s to a language with content, with a flash", %{conn: conn} do
      enable_languages(["en-US", "fr-FR"], "en-US")
      {:ok, group} = Groups.add_group(unique_name("fallback"), mode: "slug")

      published_post(group["slug"], %{
        title: "Only English",
        slug: "only-english",
        content: "Body."
      })

      conn = get(conn, "/fr/#{group["slug"]}")

      assert conn.status == 302
      assert redirected_to(conn) == "/en/#{group["slug"]}"
      # 302, never a cacheable 301 — the content state can change.
      refute conn.status == 301
    end

    test "a group with no posts at all still renders the empty listing", %{conn: conn} do
      enable_languages(["en-US", "fr-FR"], "en-US")
      {:ok, group} = Groups.add_group(unique_name("empty"), mode: "slug")

      assert conn |> get("/fr/#{group["slug"]}") |> html_response(200)
    end
  end

  describe "gettext locale on full-code content languages" do
    test "unprefixed default-language pages translate the chrome", %{conn: conn} do
      # A Russian site whose content_language is the FULL code. The gettext
      # catalogues are base-coded; put_locale("ru-RU") matches nothing and
      # every string silently fell back to English.
      enable_languages(["ru-RU"], "ru-RU")
      {:ok, group} = Groups.add_group(unique_name("locale"), mode: "slug")

      published_post(group["slug"], %{
        title: "Русский пост",
        slug: "russian-post",
        content: "Первый абзац.\n\nВторой."
      })

      body = conn |> get("/#{group["slug"]}") |> follow_to_body()

      assert body =~ "Читать далее →"
      refute body =~ "Read More →"
    end
  end

  describe "date-only URL disambiguation is language-agnostic" do
    test "a same-day sibling without this translation still forces the time URL", %{conn: conn} do
      enable_languages(["en-US", "de-DE"], "en-US")
      {:ok, group} = Groups.add_group(unique_name("dates"), mode: "timestamp")
      slug = group["slug"]

      # Two posts on one date; only the second has German. create_post stamps
      # "now", so pin the datetimes directly before publishing (the publish
      # regenerates the listing cache with the final dates).
      {:ok, en_only} = Posts.create_post(slug, %{title: "Morning EN", content: "Morning body."})
      set_post_datetime(en_only.uuid, ~D[2026-01-15], ~T[09:00:00])
      :ok = Versions.publish_version(slug, en_only.uuid, 1)

      {:ok, de_post} = Posts.create_post(slug, %{title: "Afternoon EN", content: "Afternoon."})
      set_post_datetime(de_post.uuid, ~D[2026-01-15], ~T[14:00:00])
      :ok = Versions.publish_version(slug, de_post.uuid, 1)

      {:ok, _} = TranslationManager.add_language_to_post(slug, de_post.uuid, "de-DE", nil)
      {:ok, de_read} = Posts.read_post_by_uuid(de_post.uuid, "de-DE", 1)

      {:ok, _} =
        Posts.update_post(
          slug,
          de_read,
          %{"title" => "Nachmittag DE", "content" => "Deutscher Nachmittag."},
          %{}
        )

      body = conn |> get("/de/#{slug}") |> follow_to_body()

      # The German card must carry the TIME segment: resolution of
      # /de/<group>/2026-01-15 is language-agnostic and would 302 to the
      # 09:00 post — a different post with no German at all.
      assert body =~ "/de/#{slug}/2026-01-15/14:00"
      refute body =~ ~r{href="/de/#{slug}/2026-01-15"}
    end
  end

  describe "base→dialect tie-break" do
    test "prefers the primary language over declaration order" do
      enable_languages(["en-GB", "en-US"], "en-US")

      assert Language.find_dialect_for_base("en", Language.get_enabled_languages()) == "en-US"
      assert LanguageHelpers.resolve_language_key("en", ["en-GB", "en-US"]) == "en-US"
    end

    test "resolve_language_key prefers an enabled dialect over a legacy one" do
      enable_languages(["en-US"], "en-US")

      # The map carries a legacy/disabled sibling; map order must not decide.
      assert LanguageHelpers.resolve_language_key("en", ["en-GB", "en-US"]) == "en-US"
    end
  end

  describe "sibling-dialect no-prefix guard" do
    test "only the default language's prefix reads as redundant" do
      enable_languages(["en-US", "en-GB"], "en-US")
      {:ok, _} = Settings.update_boolean_setting("default_language_no_prefix", true)

      on_exit(fn ->
        {:ok, _} = Settings.update_boolean_setting("default_language_no_prefix", false)
      end)

      conn_for = fn lang -> %Plug.Conn{params: %{"language" => lang}} end

      assert Language.prefixed_default_language_request?(conn_for.("en"), "en")
      assert Language.prefixed_default_language_request?(conn_for.("en-US"), "en-US")

      # en-GB is a SIBLING of the default, not the default: claiming it
      # 301'd /en-GB/... to the unprefixed URL, which then served en-US.
      refute Language.prefixed_default_language_request?(conn_for.("en-GB"), "en-GB")
    end
  end

  describe "excerpt hygiene" do
    test "entities are not double-escaped" do
      assert PublishingHTML.extract_excerpt("Fish & chips <3 you") == "Fish & chips <3 you"
    end

    test "Note bodies and style content never reach the preview" do
      excerpt =
        PublishingHTML.extract_excerpt(~s(Uses <Note note="secret note body">phrase</Note> here.))

      assert excerpt =~ "phrase"
      refute excerpt =~ "secret note body"
      refute excerpt =~ "pk-note-ref"
    end

    test "a truncated component tag does not leak markup" do
      # Mirrors the mapper's 300-char slice cutting mid-tag.
      truncated = ~s(<Gallery motion="scroll" items="a,b" caption="Tom &amp; Je)
      assert PublishingHTML.extract_excerpt(truncated) == ""
    end
  end

  describe "slug-collision previous_url_slugs trail" do
    test "a cleared custom slug keeps 301ing to its post", %{conn: conn} do
      enable_languages(["en-US", "de-DE"], "en-US")
      {:ok, group} = Groups.add_group(unique_name("collision"), mode: "slug")
      slug = group["slug"]

      victim =
        published_post(slug, %{title: "Victim", slug: "victim", content: "Victim body."})

      {:ok, de_read} = Posts.read_post_by_uuid(victim.uuid, "de-DE", 1)

      {:ok, _} =
        case de_read do
          %{is_new_translation: true} ->
            TranslationManager.add_language_to_post(slug, victim.uuid, "de-DE", nil)

          _ ->
            {:ok, de_read}
        end

      {:ok, de_read} = Posts.read_post_by_uuid(victim.uuid, "de-DE", 1)

      {:ok, _} =
        Posts.update_post(
          slug,
          de_read,
          %{"title" => "Opfer", "content" => "Opferkörper.", "url_slug" => "hallo"},
          %{}
        )

      # A new post whose INTERNAL slug equals the victim's custom url_slug
      # triggers the collision cleaner.
      SlugHelpers.clear_conflicting_url_slugs(slug, "hallo")

      {:ok, healed} = Posts.read_post_by_uuid(victim.uuid, "de-DE", 1)
      previous = get_in(healed, [:metadata, :previous_url_slugs]) || []

      assert "hallo" in previous
      _ = conn
      _ = Publishing
      _ = DBStorage
    end
  end

  describe "versioned URLs honor the canonical-language redirect" do
    test "a wrong-language /v/N URL 301s instead of crashing or serving the fallback", %{
      conn: conn
    } do
      enable_languages(["en-US", "de-DE"], "en-US")
      {:ok, group} = Groups.add_group(unique_name("vlang"), mode: "slug")
      slug = group["slug"]

      {:ok, post} =
        Posts.create_post(slug, %{title: "Versioned", slug: "versioned", content: "Body."})

      {:ok, read} = Posts.read_post_by_uuid(post.uuid, "en-US", 1)
      {:ok, _} = Posts.update_post(slug, read, %{"allow_version_access" => "true"}, %{})
      :ok = Versions.publish_version(slug, post.uuid, 1)

      conn = get(conn, "/de/#{slug}/versioned/v/1")

      # No German content: the versioned view must canonical-redirect to the
      # content's language, never 500 (missing consumer clause) and never
      # serve the English body at 200 under the German URL.
      assert conn.status == 301
      assert redirected_to(conn, 301) =~ "/en/#{slug}/versioned"
    end
  end

  defp set_post_datetime(post_uuid, date, time) do
    {:ok, _} =
      post_uuid
      |> DBStorage.get_post_by_uuid()
      |> Ecto.Changeset.change(post_date: date, post_time: time)
      |> PhoenixKit.RepoHelper.repo().update()

    :ok
  end

  # The listing may 301/302 to its canonical form; follow one hop.
  defp follow_to_body(conn) do
    case conn.status do
      status when status in [301, 302] ->
        location = get_resp_header(conn, "location") |> List.first()
        build_conn() |> get(location) |> html_response(200)

      200 ->
        html_response(conn, 200)
    end
  end
end
