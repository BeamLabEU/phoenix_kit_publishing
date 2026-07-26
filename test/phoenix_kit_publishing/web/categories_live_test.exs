defmodule PhoenixKit.Modules.Publishing.Web.CategoriesLiveTest do
  @moduledoc """
  Smoke + behavior tests for the admin categories management page: tree
  render, create/edit/delete flows, and the cycle guard surfacing as a
  flash rather than a crash.
  """

  use PhoenixKitPublishing.LiveCase, async: false

  alias PhoenixKit.Modules.Publishing.Categories
  alias PhoenixKit.Modules.Publishing.Groups

  defp unique_name, do: "catlv-#{System.unique_integer([:positive])}"

  setup %{conn: conn} do
    {:ok, group} = Groups.add_group(unique_name(), mode: "slug")
    scope = fake_scope()
    conn = put_test_scope(conn, scope)
    %{conn: conn, group: group, slug: group["slug"]}
  end

  test "renders the tree with counts and creates a category", %{conn: conn, slug: slug} do
    {:ok, view, html} = live(conn, "/admin/publishing/categories/#{slug}")
    assert html =~ "No categories yet"

    view
    |> form("#category-form", category: %{"name" => "News", "slug" => "", "position" => "1"})
    |> render_submit()

    html = render(view)
    assert html =~ "News"
    assert html =~ "news"
    assert [{%{name: "News"}, 0}] = Categories.list_tree(slug)
  end

  test "edits a category via the form", %{conn: conn, slug: slug} do
    {:ok, cat} = Categories.create_category(slug, %{"name" => "Old"})
    {:ok, view, _} = live(conn, "/admin/publishing/categories/#{slug}")

    view |> element("button[phx-value-uuid='#{cat.uuid}'][phx-click='edit']") |> render_click()

    view
    |> form("#category-form", category: %{"name" => "Renamed", "slug" => cat.slug})
    |> render_submit()

    assert render(view) =~ "Renamed"
    {:ok, reloaded} = Categories.get_category(cat.uuid)
    assert reloaded.name == "Renamed"
  end

  test "editing a category excludes itself and descendants from the parent picker", %{
    conn: conn,
    slug: slug
  } do
    {:ok, a} = Categories.create_category(slug, %{"name" => "A"})
    {:ok, b} = Categories.create_category(slug, %{"name" => "B", "parent_uuid" => a.uuid})
    {:ok, other} = Categories.create_category(slug, %{"name" => "Other"})

    {:ok, view, _} = live(conn, "/admin/publishing/categories/#{slug}")
    view |> element("button[phx-value-uuid='#{a.uuid}'][phx-click='edit']") |> render_click()

    html = render(view)
    # The select offers only valid parents: not A itself, not its child B.
    refute html =~ ~s(value="#{a.uuid}")
    refute html =~ ~s(<option value="#{b.uuid}")
    assert html =~ ~s(<option value="#{other.uuid}")

    # The context still guards a raced/direct invalid re-parent.
    assert {:error, :category_cycle} =
             Categories.update_category(a.uuid, %{"parent_uuid" => b.uuid})
  end

  test "deletes a category from the tree", %{conn: conn, slug: slug} do
    {:ok, cat} = Categories.create_category(slug, %{"name" => "Gone"})
    {:ok, view, _} = live(conn, "/admin/publishing/categories/#{slug}")

    view |> element("button[phx-value-uuid='#{cat.uuid}'][phx-click='delete']") |> render_click()

    refute render(view) =~ "Gone"
    assert Categories.list_tree(slug) == []
  end

  test "unknown group redirects away", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: to}}} =
             live(conn, "/admin/publishing/categories/no-such-group")

    assert to =~ "/admin/publishing"
  end
end
