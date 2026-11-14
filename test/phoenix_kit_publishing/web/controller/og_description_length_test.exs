defmodule PhoenixKit.Modules.Publishing.Web.Controller.OgDescriptionLengthTest do
  @moduledoc """
  Pins the length rule of the post page's description: the one derived from
  the body is shortened to a search-result length (~160 graphemes, at a
  sentence end when one fits), while a description the author wrote — the
  per-post `og` override or the version description — is used whole. Also
  pins that `<meta name="description">` rides along with the og tags.
  """

  use PhoenixKitPublishing.ConnCase, async: false

  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.Posts
  alias PhoenixKit.Modules.Publishing.Versions
  alias PhoenixKit.Settings

  @first "Our garden has grown a great deal this year, and most of the credit goes to the rain."
  @second " The tomatoes, beans and squash all came in early."
  @third " Then came the long dry spell in August that nobody had planned for at all."

  @long_explicit String.duplicate("An explicit description the author wrote. ", 8)

  setup do
    {:ok, _} = Settings.update_boolean_setting("publishing_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("publishing_public_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("publishing_render_og_tags", true)
    {:ok, _} = Settings.update_boolean_setting("languages_enabled", false)
    {:ok, _} = Settings.update_setting("content_language", "en")

    {:ok, group} =
      Groups.add_group("og-length-#{System.unique_integer([:positive])}", mode: "slug")

    %{group_slug: group["slug"]}
  end

  defp publish(group_slug, slug, content, attrs \\ %{}) do
    {:ok, post} =
      Posts.create_post(group_slug, %{title: "T #{slug}", slug: slug, content: content})

    if attrs != %{} do
      {:ok, read} = Publishing.read_post_by_uuid(post.uuid, "en", 1)
      {:ok, _} = Posts.update_post(group_slug, read, attrs, %{})
    end

    :ok = Versions.publish_version(group_slug, post.uuid, 1)
  end

  test "a derived description is cut at a sentence end within 160 graphemes", %{
    conn: conn,
    group_slug: group_slug
  } do
    publish(group_slug, "garden", @first <> @second <> @third <> "\n\nSecond paragraph.")

    conn = get(conn, "/#{group_slug}/garden")
    html = html_response(conn, 200)
    expected = @first <> @second

    assert conn.assigns.og.description == expected
    assert String.length(expected) <= 160
    assert html =~ ~s(<meta property="og:description" content="#{expected}">)
    assert html =~ ~s(<meta name="description" content="#{expected}">)
    refute conn.assigns.og.description =~ "nobody had planned"
  end

  test "an explicit og override is not trimmed", %{conn: conn, group_slug: group_slug} do
    publish(group_slug, "override", @first <> @second <> @third, %{
      "og_description" => @long_explicit
    })

    conn = get(conn, "/#{group_slug}/override")

    assert conn.assigns.og.description == String.trim(@long_explicit)
    assert String.length(conn.assigns.og.description) > 160
  end

  test "the version description used as a last resort is not trimmed", %{
    conn: conn,
    group_slug: group_slug
  } do
    publish(group_slug, "bodyless", "", %{"description" => @long_explicit})

    conn = get(conn, "/#{group_slug}/bodyless")

    assert String.length(conn.assigns.og.description) > 160
  end
end
