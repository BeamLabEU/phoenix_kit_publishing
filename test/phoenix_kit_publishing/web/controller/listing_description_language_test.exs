defmodule PhoenixKit.Modules.Publishing.Web.Controller.ListingDescriptionLanguageTest do
  @moduledoc """
  Pins that listing-card previews and feed item descriptions always derive
  from the per-language content — never from the version-level
  `data["description"]`.

  That field has no editor UI and carries no language (legacy V1 promotion
  hoists whichever language's content.data was edited; API callers can write
  it), so when it drove the preview, multi-language groups showed one
  language's text under every language's title: switch the listing language
  and the titles change but the preview stays put.

  Its one remaining job is the og:description default on post pages
  (`build_og_data/4`) — the last test pins that it keeps doing that.
  """

  # async: false — mutates the global publishing + language settings rows.
  use PhoenixKitPublishing.ConnCase, async: false

  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.Posts
  alias PhoenixKit.Modules.Publishing.TranslationManager
  alias PhoenixKit.Modules.Publishing.Versions
  alias PhoenixKit.Settings

  @description "Explicit English SEO description"
  @en_paragraph "English intro paragraph before anything else."
  @de_paragraph "Deutscher Einleitungsabsatz vor allem anderen."

  defp unique_name, do: "desc-lang-#{System.unique_integer([:positive])}"

  setup do
    {:ok, _} = Settings.update_boolean_setting("publishing_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("publishing_public_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("publishing_feeds_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("languages_enabled", true)
    {:ok, _} = Settings.update_setting("content_language", "en-US")

    {:ok, _} =
      Settings.update_json_setting("languages_config", %{
        "languages" => [
          %{
            "code" => "en-US",
            "name" => "English",
            "is_default" => true,
            "is_enabled" => true,
            "position" => 0
          },
          %{
            "code" => "de-DE",
            "name" => "German",
            "is_default" => false,
            "is_enabled" => true,
            "position" => 1
          }
        ]
      })

    {:ok, group} = Groups.add_group(unique_name(), mode: "slug")
    slug = group["slug"]

    {:ok, post} =
      Posts.create_post(slug, %{
        title: "Hello",
        slug: "hello",
        content: @en_paragraph <> "\n\nSecond paragraph."
      })

    # German translation with a clearly distinct body.
    {:ok, _} = TranslationManager.add_language_to_post(slug, post.uuid, "de-DE", nil)
    {:ok, de_read} = Publishing.read_post_by_uuid(post.uuid, "de-DE", 1)

    {:ok, _} =
      Posts.update_post(
        slug,
        de_read,
        %{"title" => "Hallo", "content" => @de_paragraph <> "\n\nZweiter Absatz."},
        %{}
      )

    # Version-level description (the language-blind field under test).
    {:ok, en_read} = Publishing.read_post_by_uuid(post.uuid, "en-US", 1)
    {:ok, _} = Posts.update_post(slug, en_read, %{"description" => @description}, %{})

    :ok = Versions.publish_version(slug, post.uuid, 1)

    %{group_slug: slug, post: post}
  end

  test "primary-language listing previews the post text, not the description", %{
    conn: conn,
    group_slug: slug
  } do
    body = conn |> get("/en/#{slug}") |> follow_to_body()

    assert body =~ @en_paragraph
    refute body =~ @description
  end

  test "non-primary listing previews that language's text, not the description", %{
    conn: conn,
    group_slug: slug
  } do
    body = conn |> get("/de/#{slug}") |> follow_to_body()

    # The reported bug: the title switched language while the preview stayed
    # on the version description.
    assert body =~ "Hallo"
    assert body =~ @de_paragraph
    refute body =~ @description
  end

  test "feed items use the per-language excerpt in every language", %{
    conn: conn,
    group_slug: slug
  } do
    en_feed = conn |> get("/en/#{slug}/feed.xml") |> response(200)
    assert en_feed =~ @en_paragraph
    refute en_feed =~ @description

    de_feed = build_conn() |> get("/de/#{slug}/feed.xml") |> response(200)
    assert de_feed =~ @de_paragraph
    refute de_feed =~ @description
  end

  test "og:description derives from the page's own language", %{
    conn: conn,
    group_slug: slug
  } do
    en = conn |> get("/en/#{slug}/hello") |> follow_to_body()
    assert en =~ ~s(<meta property="og:description" content="#{@en_paragraph}")
    refute en =~ ~s(content="#{@description}")

    de = build_conn() |> get("/de/#{slug}/hello") |> follow_to_body()
    assert de =~ ~s(<meta property="og:description" content="#{@de_paragraph}")
    refute de =~ ~s(content="#{@description}")
  end

  test "og:description falls back to the version description only when the language has no body",
       %{conn: conn, group_slug: slug} do
    {:ok, bodyless} =
      Posts.create_post(slug, %{title: "Empty Body", slug: "empty-body", content: ""})

    {:ok, read} = Publishing.read_post_by_uuid(bodyless.uuid, "en-US", 1)
    {:ok, _} = Posts.update_post(slug, read, %{"description" => "Last-resort description"}, %{})
    :ok = Versions.publish_version(slug, bodyless.uuid, 1)

    body = conn |> get("/en/#{slug}/empty-body") |> follow_to_body()
    assert body =~ ~s(<meta property="og:description" content="Last-resort description")
  end

  # The listing may 301 to its canonical language form (prefix handling);
  # follow one hop so assertions run against the rendered page either way.
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
