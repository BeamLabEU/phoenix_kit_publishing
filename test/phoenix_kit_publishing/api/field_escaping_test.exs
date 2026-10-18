defmodule PhoenixKit.Modules.Publishing.API.FieldEscapingTest do
  @moduledoc """
  The text fields the API's text rule does NOT scan (title, description, seo_title, excerpt,
  og_*, category name and description) must render escaped on every public surface. A field that
  renders raw joins the scan.
  """

  # async: false: mutates the global publishing settings rows.
  use PhoenixKitPublishing.ConnCase, async: false

  alias PhoenixKit.Modules.Publishing.{Categories, Groups, Posts, Versions}
  alias PhoenixKit.Settings

  @marker ~s(<b id="marker">x</b>)
  @raw ~s(<b id="marker">)
  @escaped "&lt;b id=&quot;marker&quot;&gt;"

  setup do
    {:ok, _} = Settings.update_boolean_setting("publishing_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("publishing_public_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("publishing_feeds_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("languages_enabled", false)
    {:ok, _} = Settings.update_setting("content_language", "en")

    {:ok, group} =
      Groups.add_group("#{@marker} #{System.unique_integer([:positive])}", mode: "slug")

    {:ok, cat} =
      Categories.create_category(group["slug"], %{
        "name" => @marker,
        "slug" => "marked",
        "description" => @marker
      })

    {:ok, post} =
      Posts.create_post(group["slug"], %{
        title: @marker,
        slug: "marked-post",
        content: "plain body"
      })

    {:ok, full} = Posts.read_post_by_uuid(post.uuid)

    {:ok, _} =
      Posts.update_post(
        group["slug"],
        full,
        %{
          "description" => @marker,
          "seo_title" => @marker,
          "excerpt" => @marker,
          "og_title" => @marker,
          "og_description" => @marker
        },
        publish: false
      )

    {:ok, _} = Categories.replace_post_categories(post.uuid, [cat.uuid])
    :ok = Versions.publish_version(group["slug"], post.uuid, 1)
    %{slug: group["slug"], post_uuid: post.uuid}
  end

  test "no post page, listing, category archive or feed renders a marked field raw", %{
    conn: conn,
    slug: slug
  } do
    for path <- [
          "/#{slug}/marked-post",
          "/#{slug}",
          "/#{slug}/category/marked",
          "/#{slug}/feed.xml"
        ] do
      body = conn |> get(path) |> response(200)
      refute body =~ @raw, "#{path} renders a text field unescaped"

      assert body =~ @escaped,
             "#{path} no longer carries the marked fields, so the check is vacuous"
    end
  end

  test "the harness can see raw output: a BODY with the marker renders raw (markdown is unsafe by design)",
       %{conn: conn, slug: slug, post_uuid: uuid} do
    {:ok, full} = Posts.read_post_by_uuid(uuid)
    {:ok, _} = Posts.update_post(slug, full, %{"content" => "text " <> @marker}, publish: false)
    body = conn |> get("/#{slug}/marked-post") |> response(200)
    assert body =~ @raw, "if this fails the escaping test above proves nothing"
  end
end
