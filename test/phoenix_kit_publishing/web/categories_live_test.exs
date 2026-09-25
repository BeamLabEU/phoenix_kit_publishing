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
  alias PhoenixKit.Utils.Tree

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

    assert has_element?(view, parent_input("category", parent.uuid))

    view
    |> form("#category-form", category: %{"name" => "Child"})
    |> render_submit()

    assert [{%{name: "Parent"}, 0}, {%{name: "Child"}, 1}] = Categories.list_tree(slug)
  end

  test "a parent picked in the form's tree is where the category saves", %{
    conn: conn,
    slug: slug
  } do
    {:ok, parent} = Categories.create_category(slug, %{"name" => "Parent"})
    {:ok, view, _} = live(conn, "/admin/publishing/categories/#{slug}")
    view |> element("button[phx-click='new']") |> render_click()

    view |> element("#category-parent-picker-change") |> render_click()
    view |> element(row("category-parent-picker", parent.uuid)) |> render_click()
    assert has_element?(view, parent_input("category", parent.uuid))

    # The top-level row takes it back to no parent.
    view |> element("#category-parent-picker-change") |> render_click()
    view |> element(row("category-parent-picker", "root")) |> render_click()
    assert has_element?(view, parent_input("category", ""))

    view |> element("#category-parent-picker-change") |> render_click()
    view |> element(row("category-parent-picker", parent.uuid)) |> render_click()
    view |> form("#category-form", category: %{"name" => "Child"}) |> render_submit()

    assert [{%{name: "Parent"}, 0}, {%{name: "Child"}, 1}] = Categories.list_tree(slug)
  end

  test "a validate still carrying the old parent does not undo a pick", %{
    conn: conn,
    slug: slug
  } do
    {:ok, parent} = Categories.create_category(slug, %{"name" => "Parent"})
    {:ok, view, _} = live(conn, "/admin/publishing/categories/#{slug}")
    view |> element("button[phx-click='new']") |> render_click()

    view |> element("#category-parent-picker-change") |> render_click()
    view |> element(row("category-parent-picker", parent.uuid)) |> render_click()

    # A keystroke sent before the pick's patch reached the browser.
    render_change(view, "validate", %{"category" => %{"name" => "Chi", "parent_uuid" => ""}})
    assert has_element?(view, parent_input("category", parent.uuid))

    render_submit(view, "save", %{"category" => %{"name" => "Child", "parent_uuid" => ""}})
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

    view |> element("#category-parent-picker-change") |> render_click()
    # The picker offers only valid parents: not A itself, not its child B.
    refute has_element?(view, row("category-parent-picker", a.uuid))
    refute has_element?(view, row("category-parent-picker", b.uuid))
    assert has_element?(view, row("category-parent-picker", other.uuid))

    # The context still guards a raced/direct invalid re-parent.
    assert {:error, :category_cycle} =
             Categories.update_category(a.uuid, %{"parent_uuid" => b.uuid})
  end

  test "Save after a move made elsewhere keeps the category where it is", %{
    conn: conn,
    slug: slug
  } do
    {:ok, p} = Categories.create_category(slug, %{"name" => "P"})
    {:ok, q} = Categories.create_category(slug, %{"name" => "Q"})
    {:ok, c} = Categories.create_category(slug, %{"name" => "C", "parent_uuid" => p.uuid})

    {:ok, view, _} = live(conn, "/admin/publishing/categories/#{slug}")
    view |> element("button[phx-value-uuid='#{c.uuid}'][phx-click='edit']") |> render_click()

    # Another admin moves C under Q while this form sits open on P.
    {:ok, _} = Categories.move_category(c.uuid, q.uuid)

    view
    |> form("#category-form", category: %{"name" => "C renamed", "slug" => c.slug})
    |> render_submit()

    {:ok, reloaded} = Categories.get_category(c.uuid)
    assert reloaded.name == "C renamed"
    assert reloaded.parent_uuid == q.uuid
  end

  test "a parent picked on the form still moves the category", %{conn: conn, slug: slug} do
    {:ok, p} = Categories.create_category(slug, %{"name" => "P"})
    {:ok, c} = Categories.create_category(slug, %{"name" => "C", "parent_uuid" => p.uuid})

    {:ok, view, _} = live(conn, "/admin/publishing/categories/#{slug}")
    view |> element("button[phx-value-uuid='#{c.uuid}'][phx-click='edit']") |> render_click()
    view |> element("#category-parent-picker-change") |> render_click()
    view |> element(row("category-parent-picker", Tree.root_id())) |> render_click()

    view
    |> form("#category-form", category: %{"name" => "C", "slug" => c.slug})
    |> render_submit()

    {:ok, reloaded} = Categories.get_category(c.uuid)
    assert reloaded.parent_uuid == nil
  end

  test "Move-to dialog re-parents a category", %{conn: conn, slug: slug} do
    {:ok, a} = Categories.create_category(slug, %{"name" => "A"})
    {:ok, b} = Categories.create_category(slug, %{"name" => "B"})

    {:ok, view, _} = live(conn, "/admin/publishing/categories/#{slug}")

    view
    |> element("button[phx-value-uuid='#{b.uuid}'][phx-click='open_move']")
    |> render_click()

    # The dialog excludes B itself from the target tree.
    assert render(view) =~ "Move"
    refute has_element?(view, row("category-move-picker", b.uuid))

    view |> element(row("category-move-picker", a.uuid)) |> render_click()
    view |> form("#category-move-form") |> render_submit()

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

  test "Move takes the picked target, not a stale or crafted post", %{conn: conn, slug: slug} do
    {:ok, a} = Categories.create_category(slug, %{"name" => "A"})
    {:ok, b} = Categories.create_category(slug, %{"name" => "B"})
    {:ok, view, _} = live(conn, "/admin/publishing/categories/#{slug}")

    view |> element("button[phx-value-uuid='#{b.uuid}'][phx-click='open_move']") |> render_click()
    view |> element(row("category-move-picker", a.uuid)) |> render_click()

    # Sent before the pick's patch landed: still the old, top-level value.
    render_submit(view, "confirm_move", %{"move" => %{"parent_uuid" => ""}})

    {:ok, reloaded} = Categories.get_category(b.uuid)
    assert reloaded.parent_uuid == a.uuid
  end

  test "a save and a move from the page are logged with the signed-in actor", %{
    conn: conn,
    slug: slug
  } do
    editor = "019cce93-0000-7000-8000-00000000e7e7"
    conn = put_test_scope(conn, fake_scope(user_uuid: editor))
    {:ok, a} = Categories.create_category(slug, %{"name" => "A"})
    {:ok, b} = Categories.create_category(slug, %{"name" => "B"})
    {:ok, view, _} = live(conn, "/admin/publishing/categories/#{slug}")

    view |> element("button[phx-value-uuid='#{a.uuid}'][phx-click='edit']") |> render_click()

    view
    |> form("#category-form", category: %{"name" => "A2", "slug" => a.slug})
    |> render_submit()

    view |> element("button[phx-value-uuid='#{b.uuid}'][phx-click='open_move']") |> render_click()
    view |> element(row("category-move-picker", a.uuid)) |> render_click()
    render_submit(view, "confirm_move", %{})

    for uuid <- [a.uuid, b.uuid] do
      assert_activity_logged("publishing.category.updated",
        resource_uuid: uuid,
        actor_uuid: editor
      )
    end
  end

  test "a category id that is not a uuid is not found, not a crash", %{slug: slug} do
    assert {:error, :not_found} = Categories.get_category("not-a-uuid")
    assert {:error, :not_found} = Categories.move_category("not-a-uuid", nil)
    {:ok, lone} = Categories.create_category(slug, %{"name" => "Lone"})
    assert {:error, :not_found} = Categories.update_category("not-a-uuid", %{"name" => "x"})
    {:ok, still} = Categories.get_category(lone.uuid)
    assert still.name == "Lone"
  end

  test "a move to a parent that is not a uuid is refused, not a crash", %{slug: slug} do
    {:ok, lone} = Categories.create_category(slug, %{"name" => "Lone"})
    assert {:error, :parent_not_found} = Categories.move_category(lone.uuid, "root")
    {:ok, still} = Categories.get_category(lone.uuid)
    assert still.parent_uuid == nil
  end

  test "a parent that is not a uuid is refused, not a crash", %{conn: conn, slug: slug} do
    assert {:error, :parent_not_found} =
             Categories.create_category(slug, %{"name" => "X", "parent_uuid" => "root"})

    {:ok, view, _} = live(conn, "/admin/publishing/categories/#{slug}")
    render_click(view, "new_child", %{"uuid" => "not-a-uuid"})

    html = render_submit(view, "save", %{"category" => %{"name" => "Orphan"}})
    assert html =~ "That parent no longer exists."
    assert Categories.list_tree(slug) == []
  end

  test "Move-to dialog preselects the current parent", %{conn: conn, slug: slug} do
    {:ok, a} = Categories.create_category(slug, %{"name" => "A"})
    {:ok, b} = Categories.create_category(slug, %{"name" => "B", "parent_uuid" => a.uuid})

    {:ok, view, _} = live(conn, "/admin/publishing/categories/#{slug}")

    view
    |> element("button[phx-value-uuid='#{b.uuid}'][phx-click='open_move']")
    |> render_click()

    # Submitting the dialog untouched must NOT silently re-parent to root.
    assert has_element?(view, parent_input("move", a.uuid))

    view |> form("#category-move-form") |> render_submit()
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

  # Parents are picked in core's TreePicker, which posts the pick through a
  # hidden input and renders one button per offered row.
  defp parent_input(form, uuid),
    do: ~s(input[type="hidden"][name="#{form}[parent_uuid]"][value="#{uuid}"])

  defp row(picker, uuid), do: ~s(##{picker} [data-tree-node="#{uuid}"])
end
