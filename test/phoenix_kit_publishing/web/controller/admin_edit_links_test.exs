defmodule PhoenixKit.Modules.Publishing.Web.Controller.AdminEditLinksTest do
  @moduledoc """
  The category/tag archive and the versioned-post view are the two public
  branches that skipped `PhoenixKitWeb.AdminEditHelper.assign_admin_edit/3`
  (unlike the group listing and the slug/date post views, which already
  call it). Pins that an admin scope sees an "Edit Categories"/"Edit Post"
  link on both, and an anonymous request sees neither. Also pins that a
  TAG archive never gets the "Edit Categories" link — tags have no admin
  page of their own (they derive from body `#hashtags`), so linking there
  would send an admin to a page that can't touch the tag at all.
  """

  use PhoenixKitPublishing.ConnCase, async: false

  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.Categories
  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.Posts
  alias PhoenixKit.Modules.Publishing.Versions
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Auth.User

  defp unique_name, do: "admin-edit-#{System.unique_integer([:positive])}"

  defp admin_scope do
    %Scope{
      user: %User{uuid: Ecto.UUID.generate(), email: "admin@example.com"},
      authenticated?: true,
      cached_roles: ["Admin"]
    }
  end

  setup do
    {:ok, _} = Settings.update_boolean_setting("publishing_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("publishing_public_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("languages_enabled", false)
    {:ok, _} = Settings.update_setting("content_language", "en")

    {:ok, group} = Groups.add_group(unique_name(), mode: "slug")
    slug = group["slug"]

    {:ok, category} = Categories.create_category(slug, %{"name" => "Guides"})

    {:ok, post} =
      Posts.create_post(slug, %{
        title: "Archive Post",
        slug: "archive-post",
        content: "Body"
      })

    :ok = Versions.publish_version(slug, post.uuid, 1)
    {:ok, _} = Categories.replace_post_categories(post.uuid, [category.uuid])

    {:ok, read} = Publishing.read_post_by_uuid(post.uuid, "en", 1)
    {:ok, _} = Posts.update_post(slug, read, %{"allow_version_access" => "true"}, %{})

    {:ok, tagged_post} =
      Posts.create_post(slug, %{
        title: "Tagged Post",
        slug: "tagged-post",
        content: "Body #howto"
      })

    :ok = Versions.publish_version(slug, tagged_post.uuid, 1)

    %{slug: slug, category: category, post: post}
  end

  describe "category/tag archive" do
    test "an admin sees the Edit Categories link", %{conn: conn, slug: slug} do
      with_scope(admin_scope())

      html = get(conn, "/#{slug}/category/guides") |> html_response(200)

      assert html =~ "Edit Categories"
      assert html =~ "/admin/publishing/categories/#{slug}"
    end

    test "an anonymous reader sees no edit link", %{conn: conn, slug: slug} do
      html = get(conn, "/#{slug}/category/guides") |> html_response(200)

      refute html =~ "Edit Categories"
      refute html =~ "/admin/publishing/categories/#{slug}"
    end

    test "an admin sees no edit link on a tag archive", %{conn: conn, slug: slug} do
      with_scope(admin_scope())

      html = get(conn, "/#{slug}/tag/howto") |> html_response(200)

      refute html =~ "Edit Categories"
      refute html =~ "/admin/publishing/categories/#{slug}"
    end
  end

  describe "versioned post" do
    test "an admin sees the Edit Post link", %{conn: conn, slug: slug, post: post} do
      with_scope(admin_scope())

      html = get(conn, "/#{slug}/archive-post/v/1") |> html_response(200)

      assert html =~ "Edit Post"
      assert html =~ "/admin/publishing/#{slug}/#{post.uuid}/edit"
    end

    test "an anonymous reader sees no edit link", %{conn: conn, slug: slug, post: post} do
      html = get(conn, "/#{slug}/archive-post/v/1") |> html_response(200)

      refute html =~ "Edit Post"
      refute html =~ "/admin/publishing/#{slug}/#{post.uuid}/edit"
    end
  end
end
