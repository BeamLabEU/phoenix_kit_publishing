defmodule PhoenixKit.Modules.Publishing.Web.CategoriesLiveTest do
  @moduledoc """
  Smoke + behavior tests for the admin categories management page: tree
  render, modal create/edit/delete flows, the Move-to dialog, drag
  reorder (sibling-scoped), and the cycle guard surfacing as a flash
  rather than a crash.
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

  test "renders the tree with counts and creates a category via the modal", %{
    conn: conn,
    slug: slug
  } do
    {:ok, view, html} = live(conn, "/admin/publishing/categories/#{slug}")
    assert html =~ "No categories yet"

    view |> element("header button[phx-click='new']") |> render_click()

    view
    |> form("#category-form", category: %{"name" => "News", "slug" => "", "position" => "1"})
    |> render_submit()

    html = render(view)
    assert html =~ "News"
    assert html =~ "news"
    assert [{%{name: "News"}, 0}] = Categories.list_tree(slug)
  end

  test "edits a category via the kebab menu and modal form", %{conn: conn, slug: slug} do
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

  test "'New subcategory' prefills the parent", %{conn: conn, slug: slug} do
    {:ok, parent} = Categories.create_category(slug, %{"name" => "Parent"})
    {:ok, view, _} = live(conn, "/admin/publishing/categories/#{slug}")

    view
    |> element("button[phx-value-uuid='#{parent.uuid}'][phx-click='new_child']")
    |> render_click()

    assert has_element?(view, "#category-form option[selected][value='#{parent.uuid}']")

    view
    |> form("#category-form", category: %{"name" => "Child", "parent_uuid" => parent.uuid})
    |> render_submit()

    assert [{%{name: "Parent"}, 0}, {%{name: "Child"}, 1}] = Categories.list_tree(slug)
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
    refute html =~ ~s(<option value="#{a.uuid}")
    refute html =~ ~s(<option value="#{b.uuid}")
    assert html =~ ~s(<option value="#{other.uuid}")

    # The context still guards a raced/direct invalid re-parent.
    assert {:error, :category_cycle} =
             Categories.update_category(a.uuid, %{"parent_uuid" => b.uuid})
  end

  test "Move-to dialog re-parents a category", %{conn: conn, slug: slug} do
    {:ok, a} = Categories.create_category(slug, %{"name" => "A"})
    {:ok, b} = Categories.create_category(slug, %{"name" => "B"})

    {:ok, view, _} = live(conn, "/admin/publishing/categories/#{slug}")

    view
    |> element("button[phx-value-uuid='#{b.uuid}'][phx-click='open_move']")
    |> render_click()

    # The dialog excludes B itself from the target list.
    html = render(view)
    assert html =~ "Move"
    refute html =~ ~s(<option value="#{b.uuid}")

    view
    |> form("#category-move-form", move: %{"parent_uuid" => a.uuid})
    |> render_submit()

    {:ok, reloaded} = Categories.get_category(b.uuid)
    assert reloaded.parent_uuid == a.uuid
    assert [{%{name: "A"}, 0}, {%{name: "B"}, 1}] = Categories.list_tree(slug)
  end

  test "submitting Move-to unchanged is a no-op, not a silent reorder", %{
    conn: conn,
    slug: slug
  } do
    {:ok, a} = Categories.create_category(slug, %{"name" => "A", "position" => 0})
    {:ok, _b} = Categories.create_category(slug, %{"name" => "B", "position" => 1})
    {:ok, _c} = Categories.create_category(slug, %{"name" => "C", "position" => 2})

    {:ok, view, _} = live(conn, "/admin/publishing/categories/#{slug}")
    view |> element("button[phx-value-uuid='#{a.uuid}'][phx-click='open_move']") |> render_click()

    # The dialog pre-selects A's current parent (root), so clicking Move
    # without touching the select must change nothing. It used to append A at
    # the end of its own group — B, C, A — from one careless click.
    view |> form("#category-move-form", move: %{"parent_uuid" => ""}) |> render_submit()

    assert [{%{name: "A"}, 0}, {%{name: "B"}, 0}, {%{name: "C"}, 0}] = Categories.list_tree(slug)
  end

  test "a cross-parent drop says so instead of flashing success", %{conn: conn, slug: slug} do
    {:ok, parent} = Categories.create_category(slug, %{"name" => "Parent"})

    {:ok, child} =
      Categories.create_category(slug, %{"name" => "Kid", "parent_uuid" => parent.uuid})

    {:ok, view, _} = live(conn, "/admin/publishing/categories/#{slug}")

    # Dragging the child out to the root is discarded server-side (reorder only
    # renumbers within a parent), so claiming success while the row snaps back
    # tells the user a reparent happened.
    html =
      render_hook(view, "reorder_categories", %{
        "ordered_ids" => [child.uuid, parent.uuid],
        "moved_id" => child.uuid
      })

    assert html =~ "Move to"
    {:ok, reloaded} = Categories.get_category(child.uuid)
    assert reloaded.parent_uuid == parent.uuid
  end

  test "drag reorder renumbers siblings and never re-parents", %{conn: conn, slug: slug} do
    {:ok, a} = Categories.create_category(slug, %{"name" => "A", "position" => 0})
    {:ok, b} = Categories.create_category(slug, %{"name" => "B", "position" => 1})
    {:ok, child} = Categories.create_category(slug, %{"name" => "Child", "parent_uuid" => a.uuid})

    {:ok, view, _} = live(conn, "/admin/publishing/categories/#{slug}")

    # Client sends the whole flattened DOM order; B dropped before A, with
    # the child interleaved as a cross-parent drop attempt.
    view
    |> render_hook("reorder_categories", %{
      "ordered_ids" => [b.uuid, child.uuid, a.uuid],
      "moved_id" => b.uuid
    })

    assert [{%{name: "B"}, 0}, {%{name: "A"}, 0}, {%{name: "Child"}, 1}] =
             Categories.list_tree(slug)

    # The cross-parent placement did not re-parent the child.
    {:ok, reloaded_child} = Categories.get_category(child.uuid)
    assert reloaded_child.parent_uuid == a.uuid
  end

  test "malformed reorder payload flashes an error instead of crashing", %{
    conn: conn,
    slug: slug
  } do
    {:ok, a} = Categories.create_category(slug, %{"name" => "A"})
    {:ok, view, _} = live(conn, "/admin/publishing/categories/#{slug}")

    assert view
           |> render_hook("reorder_categories", %{"bogus" => true}) =~
             "Failed to save the new order"

    # A crafted non-binary moved_id must not crash the flash push.
    render_hook(view, "reorder_categories", %{"ordered_ids" => [a.uuid], "moved_id" => 123})
    assert render(view) =~ "A"

    # Malformed confirm_move payloads are ignored, not crashes.
    render_hook(view, "confirm_move", %{"move" => nil})
    assert render(view) =~ "A"
  end

  test "Move-to dialog preselects the current parent", %{conn: conn, slug: slug} do
    {:ok, a} = Categories.create_category(slug, %{"name" => "A"})
    {:ok, b} = Categories.create_category(slug, %{"name" => "B", "parent_uuid" => a.uuid})

    {:ok, view, _} = live(conn, "/admin/publishing/categories/#{slug}")

    view
    |> element("button[phx-value-uuid='#{b.uuid}'][phx-click='open_move']")
    |> render_click()

    # Submitting the dialog untouched must NOT silently re-parent to root.
    assert has_element?(view, "#category-move-form option[selected][value='#{a.uuid}']")

    view |> form("#category-move-form", move: %{"parent_uuid" => a.uuid}) |> render_submit()
    {:ok, reloaded} = Categories.get_category(b.uuid)
    assert reloaded.parent_uuid == a.uuid
  end

  test "events with a foreign group's uuid are rejected", %{conn: conn, slug: slug} do
    {:ok, other_group} = Groups.add_group(unique_name(), mode: "slug")
    {:ok, foreign} = Categories.create_category(other_group["slug"], %{"name" => "Foreign"})
    {:ok, _} = Categories.create_category(slug, %{"name" => "Mine"})

    {:ok, view, _} = live(conn, "/admin/publishing/categories/#{slug}")

    # Kebab buttons only render for this group's rows, so push the events
    # directly — a crafted client can do the same.
    render_hook(view, "delete", %{"uuid" => foreign.uuid})
    assert {:ok, _still_there} = Categories.get_category(foreign.uuid)

    assert render_hook(view, "edit", %{"uuid" => foreign.uuid}) =~ "Category not found"
  end

  test "deletes a category from the kebab menu", %{conn: conn, slug: slug} do
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
