defmodule PhoenixKit.Modules.Publishing.Web.HeaderTrailTest do
  @moduledoc """
  Pins the admin header trail (`page_section` / `page_crumbs` / `page_title`)
  of every admin LiveView to the core shape: the landing page carries the
  module as its title and no section; every page under it carries
  `Publishing` as the section, the levels between as crumbs, and only
  itself as the title. A title never carries its own trail.
  """

  use PhoenixKitPublishing.LiveCase

  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.Posts
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  setup do
    {:ok, _} = Settings.update_boolean_setting("languages_enabled", true)

    {:ok, group} =
      Groups.add_group("Trail LV #{System.unique_integer([:positive])}", mode: "slug")

    {:ok, post} = Posts.create_post(group["slug"], %{title: "Trail Subject"})

    %{group: group, post: post}
  end

  defp pub(rest \\ ""), do: Routes.path("/admin/publishing" <> rest)

  defp trail(conn, path) do
    {:ok, view, _html} = conn |> put_test_scope(fake_scope()) |> live(path)
    assigns = :sys.get_state(view.pid).socket.assigns

    %{
      section: {assigns[:page_section], assigns[:page_section_path]},
      crumbs: Enum.map(assigns[:page_crumbs] || [], &{&1.label, &1[:path]}),
      title: assigns[:page_title]
    }
  end

  test "landing page: the module is the title, no section", %{conn: conn} do
    assert %{section: {nil, nil}, crumbs: [], title: "Publishing"} =
             trail(conn, "/admin/publishing")
  end

  test "new group: Publishing / New group", %{conn: conn} do
    pub_path = pub()

    assert %{
             section: {"Publishing", ^pub_path},
             crumbs: [],
             title: "New group"
           } =
             trail(conn, "/admin/publishing/new-group")
  end

  test "edit group: Publishing / <group> / Edit", %{conn: conn, group: group} do
    slug = group["slug"]
    name = group["name"]
    group_path = pub("/" <> slug)
    pub_path = pub()

    assert %{
             section: {"Publishing", ^pub_path},
             crumbs: [{^name, ^group_path}],
             title: "Edit"
           } = trail(conn, "/admin/publishing/edit-group/#{slug}")
  end

  test "group listing: Publishing / <group>", %{conn: conn, group: group} do
    name = group["name"]
    pub_path = pub()

    assert %{section: {"Publishing", ^pub_path}, crumbs: [], title: ^name} =
             trail(conn, "/admin/publishing/#{group["slug"]}")
  end

  test "categories: Publishing / <group> / Categories", %{conn: conn, group: group} do
    slug = group["slug"]
    name = group["name"]
    group_path = pub("/" <> slug)

    assert %{
             section: {"Publishing", _},
             crumbs: [{^name, ^group_path}],
             title: "Categories"
           } = trail(conn, "/admin/publishing/categories/#{slug}")
  end

  test "post page: Publishing / <group> / <post>", %{conn: conn, group: group, post: post} do
    slug = group["slug"]
    name = group["name"]
    group_path = pub("/" <> slug)

    assert %{
             section: {"Publishing", _},
             crumbs: [{^name, ^group_path}],
             title: "Trail Subject"
           } = trail(conn, "/admin/publishing/#{slug}/#{post[:uuid]}")
  end

  test "new post: Publishing / <group> / New post", %{conn: conn, group: group} do
    slug = group["slug"]
    name = group["name"]
    group_path = pub("/" <> slug)

    assert %{
             section: {"Publishing", _},
             crumbs: [{^name, ^group_path}],
             title: "New post"
           } = trail(conn, "/admin/publishing/#{slug}/new")
  end

  test "edit post: Publishing / <group> / <post> / Edit", %{conn: conn, group: group, post: post} do
    slug = group["slug"]
    name = group["name"]
    group_path = pub("/" <> slug)
    post_path = pub("/#{slug}/#{post[:uuid]}")

    assert %{
             section: {"Publishing", _},
             crumbs: [
               {^name, ^group_path},
               {"Trail Subject", ^post_path}
             ],
             title: "Edit"
           } = trail(conn, "/admin/publishing/#{slug}/#{post[:uuid]}/edit")
  end

  test "preview: Publishing / <group> / <post> / Preview", %{conn: conn, group: group, post: post} do
    slug = group["slug"]
    name = group["name"]
    group_path = pub("/" <> slug)
    post_path = pub("/#{slug}/#{post[:uuid]}")

    assert %{
             section: {"Publishing", _},
             crumbs: [{^name, ^group_path}, {"Trail Subject", ^post_path}],
             title: "Preview"
           } = trail(conn, "/admin/publishing/#{slug}/#{post[:uuid]}/preview")
  end

  test "settings: Settings / Publishing", %{conn: conn} do
    settings_path = Routes.path("/admin/settings")

    assert %{
             section: {"Settings", ^settings_path},
             crumbs: [],
             title: "Publishing"
           } =
             trail(conn, "/admin/settings/publishing")
  end

  test "no title carries its own trail", %{conn: conn, group: group, post: post} do
    slug = group["slug"]

    for path <- [
          "/admin/publishing",
          "/admin/publishing/new-group",
          "/admin/publishing/edit-group/#{slug}",
          "/admin/publishing/#{slug}",
          "/admin/publishing/categories/#{slug}",
          "/admin/publishing/#{slug}/#{post[:uuid]}",
          "/admin/publishing/#{slug}/new",
          "/admin/publishing/#{slug}/#{post[:uuid]}/edit",
          "/admin/settings/publishing"
        ] do
      %{title: title} = trail(conn, path)
      refute title =~ ~r/ — | - | \/ /, "#{path} title carries a trail: #{inspect(title)}"
    end
  end
end
