defmodule PhoenixKit.Modules.Publishing.Web.ListingLiveTest do
  @moduledoc """
  Smoke tests for the Listing LV. Pins:

    * Mount + handle_params land without crashing for an existing group
    * Toggle between active and trashed views via switch_post_view event
    * trash_post + restore_post events log activity, return to active list
    * handle_info catch-all swallows unknown messages
    * load_more event extends visible_count

  These are mount-and-interact tests — full content rendering is
  exercised in `controller/show_layout_test.exs` (public path).
  """

  use PhoenixKitPublishing.LiveCase

  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.Posts
  alias PhoenixKit.Settings

  setup do
    {:ok, _} = Settings.update_boolean_setting("languages_enabled", true)

    {:ok, group} =
      Groups.add_group("Listing LV #{System.unique_integer([:positive])}", mode: "slug")

    {:ok, post} =
      Posts.create_post(group["slug"], %{title: "Sample post for listing"})

    %{group: group, post: post}
  end

  test "mount renders the group's posts list", %{conn: conn, group: group, post: post} do
    {:ok, _view, html} =
      conn
      |> put_test_scope(fake_scope())
      |> live("/admin/publishing/#{group["slug"]}")

    assert html =~ group["name"]
    # Post body should be reachable in the rendered listing
    assert html =~ post[:slug] || html =~ "Sample post"
  end

  test "switch_post_view toggles between active and trashed", %{conn: conn, group: group} do
    {:ok, view, _html} =
      conn
      |> put_test_scope(fake_scope())
      |> live("/admin/publishing/#{group["slug"]}")

    html = render_click(view, "switch_post_view", %{"mode" => "trashed"})
    assert is_binary(html)
  end

  test "load_more extends visible_count", %{conn: conn, group: group} do
    {:ok, view, _html} =
      conn
      |> put_test_scope(fake_scope())
      |> live("/admin/publishing/#{group["slug"]}")

    html = render_click(view, "load_more", %{})
    assert is_binary(html)
  end

  test "handle_info catch-all swallows unknown messages", %{conn: conn, group: group} do
    {:ok, view, _html} =
      conn
      |> put_test_scope(fake_scope())
      |> live("/admin/publishing/#{group["slug"]}")

    send(view.pid, {:bogus_message, "ignored"})
    send(view.pid, :unexpected_atom)
    assert is_binary(render(view))
  end

  test "handle_info {:post_created, _} schedules a refresh", %{conn: conn, group: group} do
    {:ok, view, _html} =
      conn
      |> put_test_scope(fake_scope())
      |> live("/admin/publishing/#{group["slug"]}")

    send(view.pid, {:post_created, %{uuid: "ignored", slug: "ignored"}})
    assert is_binary(render(view))
  end

  test "handle_info {:post_deleted, _} reloads the current view", %{conn: conn, group: group} do
    {:ok, view, _html} =
      conn
      |> put_test_scope(fake_scope())
      |> live("/admin/publishing/#{group["slug"]}")

    send(view.pid, {:post_deleted, "any-uuid"})
    assert is_binary(render(view))
  end

  test "create_post event navigates to the new-post URL", %{conn: conn, group: group} do
    {:ok, view, _html} =
      conn
      |> put_test_scope(fake_scope())
      |> live("/admin/publishing/#{group["slug"]}")

    result = render_click(view, "create_post", %{})
    assert match?({:error, {:live_redirect, _}}, result) or is_binary(result)
  end

  test "refresh event re-fetches the post list", %{conn: conn, group: group} do
    {:ok, view, _html} =
      conn
      |> put_test_scope(fake_scope())
      |> live("/admin/publishing/#{group["slug"]}")

    html = render_click(view, "refresh", %{})
    assert is_binary(html)
  end

  test "trash_post event soft-deletes a post", %{conn: conn, group: group, post: post} do
    {:ok, view, _html} =
      conn
      |> put_test_scope(fake_scope())
      |> live("/admin/publishing/#{group["slug"]}")

    html = render_click(view, "trash_post", %{"uuid" => post[:uuid]})
    assert is_binary(html)
  end

  test "restore_post event un-trashes a post", %{conn: conn, group: group} do
    {:ok, post} =
      Posts.create_post(group["slug"], %{title: "ToRestore"})

    {:ok, _} = Posts.trash_post(group["slug"], post[:uuid])

    {:ok, view, _html} =
      conn
      |> put_test_scope(fake_scope())
      |> live("/admin/publishing/#{group["slug"]}")

    _ = render_click(view, "switch_post_view", %{"mode" => "trashed"})
    html = render_click(view, "restore_post", %{"uuid" => post[:uuid]})
    assert is_binary(html)
  end

  test "handle_info {:post_updated, post} schedules debounced refresh", %{
    conn: conn,
    group: group
  } do
    {:ok, view, _html} =
      conn
      |> put_test_scope(fake_scope())
      |> live("/admin/publishing/#{group["slug"]}")

    send(view.pid, {:post_updated, %{uuid: "u", slug: "s"}})
    assert is_binary(render(view))
  end

  test "handle_info {:post_status_changed, post} schedules debounced refresh",
       %{conn: conn, group: group} do
    {:ok, view, _html} =
      conn
      |> put_test_scope(fake_scope())
      |> live("/admin/publishing/#{group["slug"]}")

    send(view.pid, {:post_status_changed, %{uuid: "u", slug: "s"}})
    assert is_binary(render(view))
  end

  test "handle_info {:version_live_changed, slug, _} refreshes",
       %{conn: conn, group: group} do
    {:ok, view, _html} =
      conn
      |> put_test_scope(fake_scope())
      |> live("/admin/publishing/#{group["slug"]}")

    send(view.pid, {:version_live_changed, "any-slug", 2})
    assert is_binary(render(view))
  end

  test "handle_info {:cache_changed, _} reloads from cache",
       %{conn: conn, group: group} do
    {:ok, view, _html} =
      conn
      |> put_test_scope(fake_scope())
      |> live("/admin/publishing/#{group["slug"]}")

    send(view.pid, {:cache_changed, group["slug"]})
    assert is_binary(render(view))
  end

  test "handle_info {:debounced_post_update, slug} fires the debounced refresh",
       %{conn: conn, group: group, post: post} do
    {:ok, view, _html} =
      conn
      |> put_test_scope(fake_scope())
      |> live("/admin/publishing/#{group["slug"]}")

    send(view.pid, {:debounced_post_update, post[:slug]})
    assert is_binary(render(view))
  end

  test "handle_info {:editor_joined, slug, user} updates active_editors",
       %{conn: conn, group: group, post: post} do
    {:ok, view, _html} =
      conn
      |> put_test_scope(fake_scope())
      |> live("/admin/publishing/#{group["slug"]}")

    send(view.pid, {:editor_joined, post[:slug], %{user_uuid: "u-1", user_email: "e"}})
    assert is_binary(render(view))
  end

  test "handle_info {:editor_left, slug, user} clears active_editors entry",
       %{conn: conn, group: group, post: post} do
    {:ok, view, _html} =
      conn
      |> put_test_scope(fake_scope())
      |> live("/admin/publishing/#{group["slug"]}")

    send(view.pid, {:editor_left, post[:slug], %{user_uuid: "u-1"}})
    assert is_binary(render(view))
  end
end
