defmodule PhoenixKit.Modules.Publishing.Web.Controller.TermArchiveTest do
  @moduledoc """
  Pins the category/tag archive contract: `/­<group>/category/<slug>` and
  `/<group>/tag/<tag>` render the term's published posts (category archives
  include descendants — the WordPress rule), unknown terms fall back, and
  the term feeds serve scoped RSS.
  """

  # async: false — mutates the global publishing settings rows.
  use PhoenixKitPublishing.ConnCase, async: false

  alias PhoenixKit.Modules.Publishing.Categories
  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.Posts
  alias PhoenixKit.Modules.Publishing.Versions
  alias PhoenixKit.Settings

  defp unique_name, do: "term-#{System.unique_integer([:positive])}"

  setup do
    {:ok, _} = Settings.update_boolean_setting("publishing_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("publishing_public_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("publishing_feeds_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("languages_enabled", false)
    {:ok, _} = Settings.update_setting("content_language", "en")

    {:ok, group} = Groups.add_group(unique_name(), mode: "slug")
    slug = group["slug"]

    {:ok, parent} = Categories.create_category(slug, %{"name" => "Guides"})

    {:ok, child} =
      Categories.create_category(slug, %{"name" => "Advanced", "parent_uuid" => parent.uuid})

    # Tags come from the body — writing them as #hashtags in the prose is the
    # only way to set them, and mirrors how a writer actually tags a post.
    publish = fn title, post_slug, tags ->
      body = Enum.map_join(tags, " ", &"##{&1}")

      {:ok, post} =
        Posts.create_post(slug, %{
          title: title,
          slug: post_slug,
          content: String.trim("Body. " <> body)
        })

      :ok = Versions.publish_version(slug, post.uuid, 1)
      post
    end

    parent_post = publish.("Parent Guide", "parent-guide", ["howto"])
    child_post = publish.("Advanced Guide", "advanced-guide", [])
    other_post = publish.("Unfiled Post", "unfiled-post", ["howto", "Extra"])

    {:ok, _} = Categories.replace_post_categories(parent_post.uuid, [parent.uuid])
    {:ok, _} = Categories.replace_post_categories(child_post.uuid, [child.uuid])

    %{
      slug: slug,
      parent: parent,
      child: child,
      parent_post: parent_post,
      child_post: child_post,
      other_post: other_post
    }
  end

  test "category archive includes descendant categories' posts", %{conn: conn, slug: slug} do
    html = get(conn, "/#{slug}/category/guides") |> html_response(200)

    assert html =~ "Category: Guides"
    assert html =~ "Parent Guide"
    # The WordPress rule: the child category's post files under the parent too.
    assert html =~ "Advanced Guide"
    refute html =~ "Unfiled Post"
  end

  test "child category archive shows only its own posts", %{conn: conn, slug: slug} do
    html = get(conn, "/#{slug}/category/advanced") |> html_response(200)
    assert html =~ "Advanced Guide"
    refute html =~ "Parent Guide"
  end

  test "tag archive matches case-insensitively", %{conn: conn, slug: slug} do
    html = get(conn, "/#{slug}/tag/HOWTO") |> html_response(200)
    assert html =~ "Tag: HOWTO"
    assert html =~ "Parent Guide"
    assert html =~ "Unfiled Post"
    refute html =~ "Advanced Guide"
  end

  test "unknown category falls back to the listing with a flash", %{conn: conn, slug: slug} do
    conn = get(conn, "/#{slug}/category/no-such")
    assert redirected_to(conn) =~ "/#{slug}"
  end

  test "unknown tag falls back to the listing", %{conn: conn, slug: slug} do
    conn = get(conn, "/#{slug}/tag/nope")
    assert redirected_to(conn) =~ "/#{slug}"
  end

  test "category feed serves scoped RSS", %{conn: conn, slug: slug} do
    conn = get(conn, "/#{slug}/category/guides/feed.xml")
    body = response(conn, 200)

    assert get_resp_header(conn, "content-type") |> List.first() =~ "application/rss+xml"
    assert body =~ "Parent Guide"
    assert body =~ "Advanced Guide"
    refute body =~ "Unfiled Post"
    assert body =~ "/#{slug}/category/guides/feed.xml"
  end

  test "tag feed serves scoped RSS", %{conn: conn, slug: slug} do
    body = get(conn, "/#{slug}/tag/howto/feed.xml") |> response(200)
    assert body =~ "Parent Guide"
    refute body =~ "Advanced Guide"
  end

  test "post page shows linked category chips when enabled, BELOW the content",
       %{conn: conn, slug: slug} do
    html = get(conn, "/#{slug}/parent-guide") |> html_response(200)
    refute html =~ "/category/guides"

    {:ok, _} = Groups.update_group(slug, %{"show_categories" => "true"})
    html = get(conn, "/#{slug}/parent-guide") |> html_response(200)
    assert html =~ "/#{slug}/category/guides"
    assert html =~ "Guides"

    # Boss call 2026-07-29: categories are filing metadata, so they belong
    # after the post body rather than between the header and the first
    # paragraph.
    [content_at, chips_at] =
      Enum.map(
        ["markdown-content", "/#{slug}/category/guides"],
        fn needle -> :binary.match(html, needle) |> elem(0) end
      )

    assert chips_at > content_at
  end

  test "the post page never lists tags as chips; body hashtags carry the links",
       %{conn: conn, slug: slug} do
    # Boss call 2026-07-29: tags aren't listed separately any more. They live
    # inline in the prose as #hashtags, already rendered as links to the same
    # archive, so a chip row only repeated them. The tag link on this page must
    # therefore appear ONLY inside the body, never as a chip in the header.
    html = get(conn, "/#{slug}/parent-guide") |> html_response(200)

    [content_at, tag_at] =
      Enum.map(
        ["markdown-content", "/#{slug}/tag/howto"],
        fn needle -> :binary.match(html, needle) |> elem(0) end
      )

    assert tag_at > content_at
    assert html =~ ">#howto</a>"
    # Exactly one — a chip row would add a second link to the same archive.
    assert length(String.split(html, "/#{slug}/tag/howto")) - 1 == 1
  end
end
