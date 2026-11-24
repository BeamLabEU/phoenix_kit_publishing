defmodule PhoenixKit.Modules.Publishing.Web.Controller.AdminEditAccountMenuTest do
  @moduledoc """
  The admin Edit target of a public page belongs in the host's account menu.

  Pins that:

    * every public page that declares an Edit target hands it to the host
      layout (`:admin_edit_url` / `:admin_edit_label` reach `Layouts.app`);
    * the target needs the "publishing" module permission, not just admin-area
      access — an admin scoped to another module gets no link anywhere;
    * the in-page Edit button is behind `publishing_show_admin_edit_button`
      and is OFF by default, while the account-menu hand-off is unconditional.
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

  @button_key "publishing_show_admin_edit_button"

  defp unique_name, do: "edit-menu-#{System.unique_integer([:positive])}"

  defp scope_with(permissions) do
    %Scope{
      user: %User{uuid: Ecto.UUID.generate(), email: "admin@example.com"},
      authenticated?: true,
      cached_roles: ["Admin"],
      cached_permissions: MapSet.new(permissions)
    }
  end

  defp publishing_admin, do: scope_with(["publishing"])
  defp other_module_admin, do: scope_with(["billing"])

  defp document(html), do: LazyHTML.from_document(html)

  # The host layout's account-menu stand-in, as the layout applied by
  # `LayoutWrapper.app_layout` sees it. The test endpoint also wraps the whole
  # response in the same layout with the raw conn assigns (a nested `main`), so
  # the selector targets the inner one: only the attrs/`module_assigns` given
  # to `app_layout` reach it, which is the boundary a real host's layout sees.
  defp host_edit_link(html),
    do: LazyHTML.query(document(html), ~s(main main [data-testid="host-admin-edit"]))

  # The in-page button: a `btn` link into the admin area inside the page body.
  defp in_page_button(html),
    do: LazyHTML.query(document(html), ~s(main a.btn[href*="/admin/publishing"]))

  defp hrefs(nodes), do: LazyHTML.attribute(nodes, "href")
  defp text(nodes), do: nodes |> LazyHTML.text() |> String.trim()

  setup do
    {:ok, _} = Settings.update_boolean_setting("publishing_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("publishing_public_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("languages_enabled", false)
    {:ok, _} = Settings.update_setting("content_language", "en")

    {:ok, group} = Groups.add_group(unique_name(), mode: "slug")
    slug = group["slug"]

    {:ok, category} = Categories.create_category(slug, %{"name" => "Guides"})

    {:ok, post} =
      Posts.create_post(slug, %{title: "Menu Post", slug: "menu-post", content: "Body"})

    :ok = Versions.publish_version(slug, post.uuid, 1)
    {:ok, _} = Categories.replace_post_categories(post.uuid, [category.uuid])

    {:ok, read} = Publishing.read_post_by_uuid(post.uuid, "en", 1)
    {:ok, _} = Posts.update_post(slug, read, %{"allow_version_access" => "true"}, %{})

    %{slug: slug, post: post}
  end

  describe "account-menu hand-off" do
    test "the group listing hands its Edit target to the host layout", %{conn: conn, slug: slug} do
      with_scope(publishing_admin())

      link = conn |> get("/#{slug}") |> html_response(200) |> host_edit_link()

      assert hrefs(link) == ["/admin/publishing/#{slug}"]
      assert text(link) == "Edit group"
    end

    test "a post page hands its Edit target to the host layout", %{
      conn: conn,
      slug: slug,
      post: post
    } do
      with_scope(publishing_admin())

      link = conn |> get("/#{slug}/menu-post") |> html_response(200) |> host_edit_link()

      assert [href] = hrefs(link)
      assert href =~ "/admin/publishing/#{slug}/#{post.uuid}/edit"
      assert text(link) == "Edit post"
    end

    test "a versioned post page hands its Edit target to the host layout", %{
      conn: conn,
      slug: slug,
      post: post
    } do
      with_scope(publishing_admin())

      link = conn |> get("/#{slug}/menu-post/v/1") |> html_response(200) |> host_edit_link()

      assert [href] = hrefs(link)
      assert href =~ "/admin/publishing/#{slug}/#{post.uuid}/edit"
    end

    test "a category archive hands its Edit target to the host layout", %{conn: conn, slug: slug} do
      with_scope(publishing_admin())

      link = conn |> get("/#{slug}/category/guides") |> html_response(200) |> host_edit_link()

      assert hrefs(link) == ["/admin/publishing/categories/#{slug}"]
      assert text(link) == "Edit categories"
    end

    test "an anonymous reader gets no target in the host layout", %{conn: conn, slug: slug} do
      html = conn |> get("/#{slug}/menu-post") |> html_response(200)

      assert Enum.empty?(host_edit_link(html))
    end
  end

  describe "module permission" do
    test "an admin without the publishing permission gets no Edit target anywhere", %{
      conn: conn,
      slug: slug
    } do
      # The in-page button is switched on so a leak would show in both places.
      {:ok, _} = Settings.update_boolean_setting(@button_key, true)
      with_scope(other_module_admin())

      for path <- ["/#{slug}", "/#{slug}/menu-post", "/#{slug}/category/guides"] do
        html = conn |> get(path) |> html_response(200)

        assert Enum.empty?(host_edit_link(html)), "host layout got an Edit target on #{path}"
        assert Enum.empty?(in_page_button(html)), "in-page Edit button rendered on #{path}"
      end
    end

    test "an admin holding the publishing permission gets the in-page button too", %{
      conn: conn,
      slug: slug
    } do
      {:ok, _} = Settings.update_boolean_setting(@button_key, true)
      with_scope(publishing_admin())

      html = conn |> get("/#{slug}/menu-post") |> html_response(200)

      assert [_] = in_page_button(html) |> Enum.to_list()
    end
  end

  describe "publishing_show_admin_edit_button" do
    test "is off by default: no in-page button, the host layout still gets the target", %{
      conn: conn,
      slug: slug
    } do
      assert Settings.get_boolean_setting(@button_key, false) == false
      with_scope(publishing_admin())

      for path <- ["/#{slug}", "/#{slug}/menu-post", "/#{slug}/category/guides"] do
        html = conn |> get(path) |> html_response(200)

        assert Enum.empty?(in_page_button(html)), "in-page button rendered on #{path}"
        assert [_] = host_edit_link(html) |> Enum.to_list()
      end
    end

    test "off: the post toolbar row is not rendered for the button alone", %{
      conn: conn,
      slug: slug
    } do
      with_scope(publishing_admin())

      html = conn |> get("/#{slug}/menu-post") |> html_response(200)

      assert Enum.empty?(LazyHTML.query(document(html), "article div.flex.flex-wrap.gap-4.mt-4"))
    end

    test "on: the in-page button renders alongside the host hand-off", %{conn: conn, slug: slug} do
      {:ok, _} = Settings.update_boolean_setting(@button_key, true)
      with_scope(publishing_admin())

      listing = conn |> get("/#{slug}") |> html_response(200)
      assert hrefs(in_page_button(listing)) == ["/admin/publishing/#{slug}"]
      assert text(in_page_button(listing)) == "Edit group"
      assert [_] = host_edit_link(listing) |> Enum.to_list()

      post = conn |> get("/#{slug}/menu-post") |> html_response(200)
      assert text(in_page_button(post)) == "Edit post"
      assert [_] = host_edit_link(post) |> Enum.to_list()
    end

    test "on: an anonymous reader still sees no button", %{conn: conn, slug: slug} do
      {:ok, _} = Settings.update_boolean_setting(@button_key, true)

      html = conn |> get("/#{slug}/menu-post") |> html_response(200)

      assert Enum.empty?(in_page_button(html))
    end
  end
end
