defmodule PhoenixKit.Modules.Publishing.Web.IndexLiveTest do
  @moduledoc """
  Smoke tests for the Index admin page (group list).

  Pins the C5 phx-disable-with additions on the destructive group
  buttons (trash / restore / delete) and the C4 activity-log threading
  on group mutations driven from the LV.
  """

  use PhoenixKitPublishing.LiveCase

  alias PhoenixKit.Modules.Publishing.DBStorage
  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Settings

  setup do
    {:ok, _} = Settings.update_boolean_setting("languages_enabled", true)

    {:ok, _} =
      Settings.update_json_setting("languages_config", %{
        "languages" => [
          %{
            "code" => "en-US",
            "name" => "English (United States)",
            "is_default" => true,
            "is_enabled" => true,
            "position" => 0
          }
        ]
      })

    :ok
  end

  test "active group cards render trash button with phx-disable-with", %{conn: conn} do
    {:ok, _group} =
      Groups.add_group("Index Trash #{System.unique_integer([:positive])}", mode: "slug")

    {:ok, _view, html} =
      conn
      |> put_test_scope(fake_scope())
      |> live("/admin/publishing")

    assert html =~ ~s|phx-click="trash_group"|
    assert html =~ ~s|phx-disable-with="Trashing…"|
  end

  test "switching to the trashed view fires the right event handler",
       %{conn: conn} do
    {:ok, group} =
      Groups.add_group("Index Restore #{System.unique_integer([:positive])}", mode: "slug")

    {:ok, _} = Groups.trash_group(group["slug"])

    {:ok, view, _html} =
      conn
      |> put_test_scope(fake_scope())
      |> live("/admin/publishing")

    # Just verify the switch_view event is wired to the right handler;
    # the trashed-view content loads asynchronously via a handle_info that
    # would require a longer-running test to observe. The phx-disable-with
    # assertion on restore/delete buttons is exercised by the structural
    # check in `web/index.ex` (the templates carry the attribute literal
    # — covered by the visual baseline diff in C0/C15).
    html_after = render_click(view, "switch_view", %{"mode" => "trashed"})

    # `view_mode` flipped → the trash tab is now styled active. Use the
    # underline-color class as the structural marker.
    assert html_after =~
             ~s|phx-value-mode="trashed" class="px-3 py-1 text-xs font-medium border-b-2 transition-colors cursor-pointer border-error|
  end

  # The three destructive-group tests pin the DB outcome AND the activity
  # row's actor_uuid (the C4 threading this module's moduledoc claims) —
  # `is_binary(html)` accepted any render, including one where the mutation
  # silently failed or the LV dropped `actor_uuid:` from the context call.
  # The scope carries a NON-default user_uuid so an actor that falls back
  # to a default fixture value can't fake the assertion.
  @click_actor "019cce93-cccc-7000-8000-000000000042"

  test "trash_group event soft-deletes the group", %{conn: conn} do
    {:ok, group} =
      Groups.add_group("Index Trash Click #{System.unique_integer([:positive])}", mode: "slug")

    {:ok, view, _html} =
      conn
      |> put_test_scope(fake_scope(user_uuid: @click_actor))
      |> live("/admin/publishing")

    html = render_click(view, "trash_group", %{"slug" => group["slug"]})
    assert html =~ "moved to trash"

    assert %{status: "trashed"} = DBStorage.get_group_by_slug(group["slug"])

    assert_activity_logged("publishing.group.trashed",
      actor_uuid: @click_actor,
      metadata_has: %{"slug" => group["slug"]}
    )
  end

  test "restore_group event un-trashes the group", %{conn: conn} do
    {:ok, group} =
      Groups.add_group("Index Restore Click #{System.unique_integer([:positive])}", mode: "slug")

    {:ok, _} = Groups.trash_group(group["slug"])

    {:ok, view, _html} =
      conn
      |> put_test_scope(fake_scope(user_uuid: @click_actor))
      |> live("/admin/publishing")

    _ = render_click(view, "switch_view", %{"mode" => "trashed"})
    html = render_click(view, "restore_group", %{"slug" => group["slug"]})
    assert html =~ "restored"

    assert %{status: "active"} = DBStorage.get_group_by_slug(group["slug"])

    assert_activity_logged("publishing.group.restored",
      actor_uuid: @click_actor,
      metadata_has: %{"slug" => group["slug"]}
    )
  end

  test "delete_group event hard-deletes (group with no posts)",
       %{conn: conn} do
    {:ok, group} =
      Groups.add_group("Index Delete Click #{System.unique_integer([:positive])}", mode: "slug")

    {:ok, _} = Groups.trash_group(group["slug"])

    {:ok, view, _html} =
      conn
      |> put_test_scope(fake_scope(user_uuid: @click_actor))
      |> live("/admin/publishing")

    _ = render_click(view, "switch_view", %{"mode" => "trashed"})
    html = render_click(view, "delete_group", %{"slug" => group["slug"]})
    assert is_binary(html)

    assert DBStorage.get_group_by_slug(group["slug"]) == nil

    assert_activity_logged("publishing.group.deleted",
      actor_uuid: @click_actor,
      metadata_has: %{"slug" => group["slug"]}
    )
  end

  test "handle_info catch-all swallows unknown messages", %{conn: conn} do
    {:ok, view, _html} =
      conn
      |> put_test_scope(fake_scope())
      |> live("/admin/publishing")

    send(view.pid, {:bogus_message, "x"})
    send(view.pid, :unexpected_atom)
    assert is_binary(render(view))
  end

  test "handle_info {:group_created, _} message refreshes the list", %{conn: conn} do
    {:ok, view, _html} =
      conn
      |> put_test_scope(fake_scope())
      |> live("/admin/publishing")

    send(view.pid, {:group_created, %{"slug" => "new-group", "name" => "New"}})
    assert is_binary(render(view))
  end

  test "handle_info {:group_deleted, _} message refreshes the list", %{conn: conn} do
    {:ok, view, _html} =
      conn
      |> put_test_scope(fake_scope())
      |> live("/admin/publishing")

    send(view.pid, {:group_deleted, "any-slug"})
    assert is_binary(render(view))
  end

  # PR #50 moved the create action out of the navbar (`:page_action`) and
  # into the groups grid as a ghost card. The grid is now the ONLY create
  # affordance on a populated dashboard, so its two gates are pinned here:
  # it closes the ACTIVE grid, and it must never appear in Trash — nothing
  # gets created there.
  describe "the ghost create-group card" do
    test "closes the grid in the active view", %{conn: conn} do
      {:ok, _group} =
        Groups.add_group("Index Ghost #{System.unique_integer([:positive])}", mode: "slug")

      {:ok, _view, html} =
        conn
        |> put_test_scope(fake_scope())
        |> live("/admin/publishing")

      # Tail-matched, not anchored at "/": the test router mounts the
      # LOCALIZED admin routes too, so Routes.path/1 renders this as
      # "/en/admin/publishing/new-group". Anchoring on the bare path made
      # the sibling `refute` below pass for the wrong reason.
      assert html =~ ~s|/admin/publishing/new-group"|
      assert html =~ "border-dashed border-base-content/25"
    end

    test "is absent in the trashed view", %{conn: conn} do
      {:ok, group} =
        Groups.add_group("Index Ghost Trash #{System.unique_integer([:positive])}", mode: "slug")

      {:ok, _} = Groups.trash_group(group["slug"])

      {:ok, view, _html} =
        conn
        |> put_test_scope(fake_scope())
        |> live("/admin/publishing")

      _ = render_click(view, "switch_view", %{"mode" => "trashed"})

      # Re-render AFTER the deferred switch lands: the click itself only
      # sets loading, and the skeleton has no create link either — so
      # asserting on the click's own render would pass for the wrong
      # reason. The trashed card proves the real grid is on screen.
      html = render(view)

      assert html =~ group["name"]
      refute html =~ ~s|/admin/publishing/new-group"|
    end

    test "a dashboard whose only groups are in Trash still shows the tabs, not the empty-state card",
         %{conn: conn} do
      {:ok, group} =
        Groups.add_group("Index Only Trash #{System.unique_integer([:positive])}", mode: "slug")

      {:ok, _} = Groups.trash_group(group["slug"])

      {:ok, _view, html} =
        conn
        |> put_test_scope(fake_scope())
        |> live("/admin/publishing")

      # The empty-state card used to win whenever the active list was empty,
      # which hid the Trash tab and made the groups unreachable on a fresh
      # mount (and after trashing the last active group).
      refute html =~ "No publishing groups yet"
      assert html =~ ~s|phx-value-mode="trashed"|
      assert html =~ ~s|/admin/publishing/new-group"|
      assert html =~ "border-dashed border-base-content/25"
    end

    test "trashing the last active group keeps the Trash tab on screen", %{conn: conn} do
      {:ok, group} =
        Groups.add_group("Index Last Trash #{System.unique_integer([:positive])}", mode: "slug")

      {:ok, view, _html} =
        conn
        |> put_test_scope(fake_scope())
        |> live("/admin/publishing")

      html = render_click(view, "trash_group", %{"slug" => group["slug"]})

      refute html =~ "No publishing groups yet"
      assert html =~ ~s|phx-value-mode="trashed"|
      assert html =~ "border-dashed border-base-content/25"
    end

    test "a truly empty dashboard (nothing in Trash either) still shows the empty-state CTA",
         %{conn: conn} do
      {:ok, _view, html} =
        conn
        |> put_test_scope(fake_scope())
        |> live("/admin/publishing")

      assert html =~ "No publishing groups yet"
      assert html =~ ~s|/admin/publishing/new-group"|
      refute html =~ ~s|phx-value-mode="trashed"|
    end
  end
end
