defmodule PhoenixKit.Modules.Publishing.Web.Controller.PostLinksTest do
  @moduledoc """
  End-to-end coverage for `[[post:UUID|Alias]]` publication mentions (PR
  #48): resolution to the target's current public URL, degradation for a
  missing/trashed/unpublished target, and that a rename after the render
  cache is warm still resolves fresh (the whole point of resolving AFTER
  the cache instead of baking the href in at render time).

  Async: false — mutates the global publishing settings rows.
  """

  use PhoenixKitPublishing.ConnCase, async: false

  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.Posts
  alias PhoenixKit.Modules.Publishing.Versions
  alias PhoenixKit.Settings

  defp unique_name, do: "post-link-#{System.unique_integer([:positive])}"

  setup do
    {:ok, _} = Settings.update_boolean_setting("publishing_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("publishing_public_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("languages_enabled", false)
    {:ok, _} = Settings.update_setting("content_language", "en")

    {:ok, group} = Groups.add_group(unique_name(), mode: "slug")
    %{slug: group["slug"]}
  end

  describe "a mention of a published post" do
    test "resolves to the target's current public URL", %{conn: conn, slug: slug} do
      {:ok, target} =
        Posts.create_post(slug, %{title: "Target Post", slug: "target-post", content: "Body."})

      :ok = Versions.publish_version(slug, target.uuid, 1)

      {:ok, source} =
        Posts.create_post(slug, %{
          title: "Source Post",
          slug: "source-post",
          content: "See [[post:#{target.uuid}|the target]] for details."
        })

      :ok = Versions.publish_version(slug, source.uuid, 1)

      html = get(conn, "/#{slug}/source-post") |> html_response(200)

      assert html =~ ~s(<a href="/#{slug}/target-post")
      assert html =~ "the target"
      assert html =~ "publishing-post-link"
    end

    test "a token with no alias uses the target's current title", %{conn: conn, slug: slug} do
      {:ok, target} =
        Posts.create_post(slug, %{title: "Untitled Alias Target", slug: "uat", content: "Body."})

      :ok = Versions.publish_version(slug, target.uuid, 1)

      {:ok, source} =
        Posts.create_post(slug, %{
          title: "Source Bare",
          slug: "source-bare",
          content: "See [[post:#{target.uuid}]] for details."
        })

      :ok = Versions.publish_version(slug, source.uuid, 1)

      html = get(conn, "/#{slug}/source-bare") |> html_response(200)
      assert html =~ "Untitled Alias Target"
    end

    test "a renamed target still resolves after the render cache is warm", %{
      conn: conn,
      slug: slug
    } do
      {:ok, target} =
        Posts.create_post(slug, %{title: "Movable Target", slug: "movable", content: "Body."})

      :ok = Versions.publish_version(slug, target.uuid, 1)

      {:ok, source} =
        Posts.create_post(slug, %{
          title: "Source Cached",
          slug: "source-cached",
          content: "See [[post:#{target.uuid}|movable target]] for details."
        })

      :ok = Versions.publish_version(slug, source.uuid, 1)

      # Warm the render cache.
      first = get(conn, "/#{slug}/source-cached") |> html_response(200)
      assert first =~ ~s(href="/#{slug}/movable")

      {:ok, reloaded} = Publishing.read_post_by_uuid(target.uuid, "en", 1)
      {:ok, _} = Posts.update_post(slug, reloaded, %{"slug" => "movable-renamed"}, %{})

      second = get(conn, "/#{slug}/source-cached") |> html_response(200)
      assert second =~ ~s(href="/#{slug}/movable-renamed")
      refute second =~ ~s(href="/#{slug}/movable")
    end
  end

  describe "a mention that can't resolve to a live target" do
    test "a missing post degrades to plain text, never a dead link", %{conn: conn, slug: slug} do
      missing_uuid = "018e3c4a-9f6b-7890-abcd-ef1234567890"

      {:ok, source} =
        Posts.create_post(slug, %{
          title: "Dangling Source",
          slug: "dangling-source",
          content: "See [[post:#{missing_uuid}|a ghost]] for details."
        })

      :ok = Versions.publish_version(slug, source.uuid, 1)

      html = get(conn, "/#{slug}/dangling-source") |> html_response(200)

      refute html =~ "<a href=\"\""
      assert html =~ "a ghost"
      refute html =~ missing_uuid
    end

    test "an unpublished target degrades to plain text", %{conn: conn, slug: slug} do
      {:ok, target} =
        Posts.create_post(slug, %{title: "Draft Target", slug: "draft-target", content: "Body."})

      # Deliberately not published.

      {:ok, source} =
        Posts.create_post(slug, %{
          title: "Points At Draft",
          slug: "points-at-draft",
          content: "See [[post:#{target.uuid}|the draft]] for details."
        })

      :ok = Versions.publish_version(slug, source.uuid, 1)

      html = get(conn, "/#{slug}/points-at-draft") |> html_response(200)

      assert html =~ "the draft"
      refute html =~ ~s(href="/#{slug}/draft-target")
    end

    test "a trashed target degrades to plain text", %{conn: conn, slug: slug} do
      {:ok, target} =
        Posts.create_post(slug, %{
          title: "Soon Trashed",
          slug: "soon-trashed",
          content: "Body."
        })

      :ok = Versions.publish_version(slug, target.uuid, 1)
      {:ok, _} = Posts.trash_post(slug, target.uuid)

      {:ok, source} =
        Posts.create_post(slug, %{
          title: "Points At Trashed",
          slug: "points-at-trashed",
          content: "See [[post:#{target.uuid}|the trashed one]] for details."
        })

      :ok = Versions.publish_version(slug, source.uuid, 1)

      html = get(conn, "/#{slug}/points-at-trashed") |> html_response(200)

      assert html =~ "the trashed one"
      refute html =~ ~s(href="/#{slug}/soon-trashed")
    end
  end

  describe "excerpts and feeds" do
    test "a listing excerpt reduces the token to its visible text", %{conn: conn, slug: slug} do
      {:ok, target} =
        Posts.create_post(slug, %{title: "Excerpt Target", slug: "excerpt-target", content: "x"})

      :ok = Versions.publish_version(slug, target.uuid, 1)

      {:ok, source} =
        Posts.create_post(slug, %{
          title: "Excerpt Source",
          slug: "excerpt-source",
          content: "Intro text mentions [[post:#{target.uuid}|a link]] mid-sentence."
        })

      :ok = Versions.publish_version(slug, source.uuid, 1)

      html = get(conn, "/#{slug}") |> html_response(200)

      refute html =~ "[[post:"
      assert html =~ "a link"
    end
  end
end
