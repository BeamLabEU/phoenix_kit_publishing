defmodule PhoenixKit.Modules.Publishing.API.FieldEscapingTest do
  @moduledoc """
  The text fields the API's text rule does NOT scan (title, description, seo_title, excerpt,
  og_*, category name and description, group name) are given a distinct markup marker each.
  Every public surface is rendered and must (a) carry the escaped form of each field it is
  known to render and (b) carry the raw form of none. A field that renders raw joins the scan.

  Fields without a public render site in this fixture (`seo_title`, the version-level
  `excerpt`, the category `description`) are covered by (b) only (setup reads them back, so
  the refute is not vacuous): the listing excerpt is derived from the body, and the
  version-level `description` is reached only as the last fallback for og:description and
  JSON-LD when the language has no body (the empty post).

  The JSON-LD script is checked on its own: it must hold the expected fields JSON-escaped
  and no `<` at all (the `Phoenix.HTML.raw/1` sink is only safe because of that), and the
  HTML expectations are checked against the page with that script removed, so the script
  cannot vouch for a field the HTML sites no longer escape.
  """

  # async: false: mutates the global publishing settings rows.
  use PhoenixKitPublishing.ConnCase, async: false

  alias PhoenixKit.Modules.Publishing.{Categories, DBStorage, Groups, Posts, Versions}
  alias PhoenixKit.Settings

  @fields ~w(group cat_name cat_description title_a description_a seo_title_a excerpt_a
             og_title_a og_description_a title_b description_b)a

  defp marker(field), do: ~s(<b id="m-#{field}">x</b>)
  defp raw(field), do: ~s(<b id="m-#{field}">)

  @jsonld_re ~r{<script type="application/ld\+json">(.*?)</script>}s

  # The JSON-LD script content, or nil; and the page without that script.
  defp jsonld(body) do
    case Regex.run(@jsonld_re, body) do
      [_, json] -> json
      nil -> nil
    end
  end

  defp without_jsonld(body), do: Regex.replace(@jsonld_re, body, "")

  # HTML-escaped, in attributes and text.
  defp html_escaped?(html, field), do: html =~ "&lt;b id=&quot;m-#{field}&quot;&gt;"

  # JSON-escaped: `<` becomes a unicode escape and quotes are backslash-escaped.
  defp json_escaped?(json, field), do: json =~ ~s(\\u003Cb id=\\"m-#{field}\\")

  setup do
    {:ok, _} = Settings.update_boolean_setting("publishing_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("publishing_public_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("publishing_feeds_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("languages_enabled", false)
    {:ok, _} = Settings.update_setting("content_language", "en")

    {:ok, group} =
      Groups.add_group("#{marker(:group)} #{System.unique_integer([:positive])}", mode: "slug")

    slug = group["slug"]

    # The category chip on the post page only renders when the group shows categories.
    {:ok, _} = Groups.update_group(slug, %{"show_categories" => true})

    {:ok, cat} =
      Categories.create_category(slug, %{
        "name" => marker(:cat_name),
        "slug" => "marked",
        "description" => marker(:cat_description)
      })

    # Post A has a body, so og:description is derived from it; every version-level field is marked.
    {:ok, post_a} =
      Posts.create_post(slug, %{
        title: marker(:title_a),
        slug: "marked-post",
        content: "plain body"
      })

    {:ok, full_a} = Posts.read_post_by_uuid(post_a.uuid)

    {:ok, _} =
      Posts.update_post(
        slug,
        full_a,
        %{
          "description" => marker(:description_a),
          "seo_title" => marker(:seo_title_a),
          "excerpt" => marker(:excerpt_a),
          "og_title" => marker(:og_title_a),
          "og_description" => marker(:og_description_a)
        },
        publish: false
      )

    # Post B has no body and no og override, so the version-level description is the
    # last fallback for og:description and JSON-LD.
    {:ok, post_b} =
      Posts.create_post(slug, %{title: marker(:title_b), slug: "empty-post", content: ""})

    {:ok, full_b} = Posts.read_post_by_uuid(post_b.uuid)

    {:ok, _} =
      Posts.update_post(slug, full_b, %{"description" => marker(:description_b)}, publish: false)

    for post <- [post_a, post_b] do
      {:ok, _} = Categories.replace_post_categories(post.uuid, [cat.uuid])
      :ok = Versions.publish_version(slug, post.uuid, 1)
    end

    # Read the fields without a render site back, so their refute is not vacuous.
    version_a = DBStorage.get_version(post_a.uuid, 1)
    assert version_a.data["seo_title"] == marker(:seo_title_a)
    assert version_a.data["excerpt"] == marker(:excerpt_a)
    assert {:ok, %{description: description}} = Categories.fetch_category(cat.uuid)
    assert description == marker(:cat_description)

    %{slug: slug, post_uuid: post_a.uuid}
  end

  test "every public surface renders the marked fields escaped and none raw", %{
    conn: conn,
    slug: slug
  } do
    expected = [
      {"/#{slug}/marked-post", [:group, :cat_name, :title_a, :og_title_a, :og_description_a],
       [:og_title_a, :og_description_a]},
      {"/#{slug}/empty-post", [:group, :cat_name, :title_b, :description_b],
       [:title_b, :description_b]},
      {"/#{slug}", [:group, :title_a, :title_b], []},
      {"/#{slug}/category/marked", [:group, :cat_name, :title_a, :title_b], []},
      {"/#{slug}/feed.xml", [:group, :title_a, :title_b], []}
    ]

    for {path, rendered, in_jsonld} <- expected do
      body = conn |> get(path) |> response(200)
      html = without_jsonld(body)
      json = jsonld(body)

      for field <- @fields do
        refute body =~ raw(field), "#{path} renders #{field} unescaped"
        refute body =~ ~s(<b id=\\"m-#{field}\\"), "#{path} renders #{field} as raw JSON"
      end

      for field <- rendered do
        assert html_escaped?(html, field),
               "#{path} no longer carries #{field}, so its escaping check is vacuous"
      end

      if in_jsonld == [] do
        assert json == nil, "#{path} unexpectedly carries a JSON-LD script"
      else
        assert json, "#{path} no longer carries a JSON-LD script"
        refute json =~ "<", "#{path} JSON-LD carries a raw angle bracket"

        for field <- in_jsonld do
          assert json_escaped?(json, field),
                 "#{path} JSON-LD no longer carries #{field}, so its escaping check is vacuous"
        end
      end
    end
  end

  test "the harness can see raw output: a BODY with the marker renders raw (markdown is unsafe by design)",
       %{conn: conn, slug: slug, post_uuid: uuid} do
    {:ok, full} = Posts.read_post_by_uuid(uuid)

    {:ok, _} =
      Posts.update_post(slug, full, %{"content" => "text " <> marker(:body)}, publish: false)

    body = conn |> get("/#{slug}/marked-post") |> response(200)
    assert body =~ raw(:body), "if this fails the escaping test above proves nothing"
  end
end
