defmodule PhoenixKit.Modules.Publishing.API.FieldEscapingTest do
  @moduledoc """
  The text fields the API's text rule does NOT scan (title, description, seo_title, excerpt,
  og_*, category name and description, group name) are given a distinct markup marker each.
  Every public surface is rendered and must (a) carry the escaped form of each field it is
  known to render and (b) carry the raw form of none. A field that renders raw joins the scan.

  Fields without a public render site in this fixture (`seo_title`, the version-level
  `excerpt`, the category `description`) are covered by (b) only: the listing excerpt is
  derived from the body, and the version-level `description` is reached only as the last
  fallback for og:description and JSON-LD when the language has no body (the empty post).
  """

  # async: false: mutates the global publishing settings rows.
  use PhoenixKitPublishing.ConnCase, async: false

  alias PhoenixKit.Modules.Publishing.{Categories, Groups, Posts, Versions}
  alias PhoenixKit.Settings

  @fields ~w(group cat_name cat_description title_a description_a seo_title_a excerpt_a
             og_title_a og_description_a title_b description_b)a

  defp marker(field), do: ~s(<b id="m-#{field}">x</b>)
  defp raw(field), do: ~s(<b id="m-#{field}">)

  # HTML-escaped (attributes and text) or JSON-escaped (JSON-LD).
  defp escaped?(body, field) do
    body =~ "&lt;b id=&quot;m-#{field}&quot;&gt;" or body =~ ~s(\\u003Cb id=\\"m-#{field}\\")
  end

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

    %{slug: slug, post_uuid: post_a.uuid}
  end

  test "every public surface renders the marked fields escaped and none raw", %{
    conn: conn,
    slug: slug
  } do
    expected = [
      {"/#{slug}/marked-post", [:group, :cat_name, :title_a, :og_title_a, :og_description_a]},
      {"/#{slug}/empty-post", [:group, :cat_name, :title_b, :description_b]},
      {"/#{slug}", [:group, :title_a, :title_b]},
      {"/#{slug}/category/marked", [:group, :cat_name, :title_a, :title_b]},
      {"/#{slug}/feed.xml", [:group, :title_a, :title_b]}
    ]

    for {path, rendered} <- expected do
      body = conn |> get(path) |> response(200)

      for field <- @fields do
        refute body =~ raw(field), "#{path} renders #{field} unescaped"
      end

      for field <- rendered do
        assert escaped?(body, field),
               "#{path} no longer carries #{field}, so its escaping check is vacuous"
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
