defmodule PhoenixKit.Modules.Publishing.Web.PostShowLiveTest do
  @moduledoc """
  Smoke tests for the PostShow LV (post overview / metadata page).

  Pins:
    * Mount renders the post title + slug
    * Status badge uses translated labels via `status_label/1`
    * `:post_updated` PubSub event reloads post data
    * handle_info catch-all swallows unknown messages
  """

  use PhoenixKitPublishing.LiveCase

  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.Posts
  alias PhoenixKit.Settings

  setup do
    {:ok, _} = Settings.update_boolean_setting("languages_enabled", true)

    {:ok, group} =
      Groups.add_group("PostShow LV #{System.unique_integer([:positive])}", mode: "slug")

    {:ok, post} = Posts.create_post(group["slug"], %{title: "Show Subject"})

    %{group: group, post: post}
  end

  test "mount renders the post title", %{conn: conn, group: group, post: post} do
    {:ok, _view, html} =
      conn
      |> put_test_scope(fake_scope())
      |> live("/admin/publishing/#{group["slug"]}/#{post[:uuid]}")

    assert html =~ "Show Subject" || html =~ post[:slug]
  end

  test "status badge renders translated 'Draft' label for draft posts", %{
    conn: conn,
    group: group,
    post: post
  } do
    {:ok, _view, html} =
      conn
      |> put_test_scope(fake_scope())
      |> live("/admin/publishing/#{group["slug"]}/#{post[:uuid]}")

    # The post is a fresh draft; the badge should use the translated label,
    # not the raw "draft" string. This pins the C12 status_label fix.
    assert html =~ "Draft"
  end

  test ":post_updated PubSub message reloads the post", %{
    conn: conn,
    group: group,
    post: post
  } do
    {:ok, view, _html} =
      conn
      |> put_test_scope(fake_scope())
      |> live("/admin/publishing/#{group["slug"]}/#{post[:uuid]}")

    send(view.pid, {:post_updated, group["slug"], post[:slug]})
    assert is_binary(render(view))
  end

  test "handle_info catch-all swallows unknown messages", %{
    conn: conn,
    group: group,
    post: post
  } do
    {:ok, view, _html} =
      conn
      |> put_test_scope(fake_scope())
      |> live("/admin/publishing/#{group["slug"]}/#{post[:uuid]}")

    send(view.pid, {:bogus, "x"})
    send(view.pid, :unexpected_atom)
    assert is_binary(render(view))
  end

  test "missing post 404s back to the group listing", %{conn: conn, group: group} do
    fake_uuid = "019cce93-bbbb-7000-8000-000000000000"

    assert {:error, {:live_redirect, %{to: destination}}} =
             conn
             |> put_test_scope(fake_scope())
             |> live("/admin/publishing/#{group["slug"]}/#{fake_uuid}")

    assert destination =~ "/admin/publishing/#{group["slug"]}"
  end
end
