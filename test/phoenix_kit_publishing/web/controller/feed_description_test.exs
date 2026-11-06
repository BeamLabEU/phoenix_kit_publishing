defmodule PhoenixKit.Modules.Publishing.Web.Controller.FeedDescriptionTest do
  @moduledoc """
  An RSS description is plain text for a feed reader.

  The excerpt behind it is Markdown: the body's first paragraph. Sent as it is,
  a reader shows `**bold**` as asterisks, and since Leaf 0.10 a typed `*` arrives
  as `\\*`, with the backslash on show. The listing cards always rendered it;
  the feed has to as well.
  """

  use PhoenixKitPublishing.ConnCase, async: false

  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.Posts
  alias PhoenixKit.Modules.Publishing.Versions
  alias PhoenixKit.Settings

  setup do
    {:ok, _} = Settings.update_boolean_setting("publishing_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("publishing_public_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("publishing_feeds_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("languages_enabled", false)
    {:ok, _} = Settings.update_setting("content_language", "en")

    {:ok, group} = Groups.add_group("feed-#{System.unique_integer([:positive])}", mode: "slug")
    %{slug: group["slug"]}
  end

  defp description(conn, slug, content) do
    {:ok, post} = Posts.create_post(slug, %{title: "T", slug: "t", content: content})
    :ok = Versions.publish_version(slug, post.uuid, 1)

    feed = get(conn, "/#{slug}/feed.xml") |> response(200)

    [_, text] =
      Regex.run(
        ~r/<description><!\[CDATA\[(.*?)\]\]><\/description>\n<\/?(?:enclosure|item)/s,
        feed
      )

    text
  end

  test "escapes Leaf wrote into the body do not reach the reader", %{conn: conn, slug: slug} do
    assert description(conn, slug, ~S(price \*is\* 5 \[x])) == "price *is* 5 [x]"
  end

  test "markdown does not reach the reader", %{conn: conn, slug: slug} do
    assert description(conn, slug, "some **bold** words") == "some bold words"
  end
end
