defmodule PhoenixKit.Modules.Publishing.Web.ProjectDocsLiveTest do
  @moduledoc """
  The Docs tab this module contributes to the projects hub, mounted the way the
  hub mounts it (`live_render` with the embed session): a linked group lists its
  published entries, an unlinked tab lists the groups to link, and the tab
  speaks the viewer's language from the session's `"locale"`.
  """

  use PhoenixKitPublishing.LiveCase

  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.Posts
  alias PhoenixKit.Modules.Publishing.Versions
  alias PhoenixKit.Modules.Publishing.Web.ProjectDocsLive

  setup do
    {:ok, group} =
      Groups.add_group("Docs tab #{System.unique_integer([:positive])}", mode: "slug")

    %{group: group}
  end

  defp mount_tab(conn, session) do
    live_isolated(conn, ProjectDocsLive, session: Map.put_new(session, "project_uuid", nil))
  end

  test "a linked group lists its published entries, not its drafts", %{conn: conn, group: group} do
    {:ok, live} = Posts.create_post(group["slug"], %{title: "Shipped entry", slug: "shipped"})
    :ok = Versions.publish_version(group["slug"], live.uuid, 1)
    {:ok, _} = Posts.create_post(group["slug"], %{title: "Unshipped entry", slug: "unshipped"})

    {:ok, _view, html} = mount_tab(conn, %{"config" => %{"group_slug" => group["slug"]}})

    assert html =~ group["name"]
    assert html =~ "Shipped entry"
    refute html =~ "Unshipped entry"
    assert html =~ "1 published entry"
  end

  test "an unlinked tab offers the groups to link", %{conn: conn, group: group} do
    {:ok, _view, html} = mount_tab(conn, %{"config" => %{}})

    assert html =~ "No publishing group linked to this project yet."
    assert html =~ group["slug"]
  end

  test "an unknown group slug is the unlinked state, not a crash", %{conn: conn} do
    {:ok, _view, html} = mount_tab(conn, %{"config" => %{"group_slug" => "no-such-group"}})
    assert html =~ "No publishing group linked to this project yet."
  end

  # A `live_render` child starts without a Gettext locale; the hub passes the
  # viewer's in the session, and the tab must apply it.
  test "the tab renders in the session's locale", %{conn: conn, group: group} do
    {:ok, _view, html} =
      mount_tab(conn, %{"config" => %{"group_slug" => group["slug"]}, "locale" => "ru"})

    assert html =~ "Ничего не опубликовано"
  end
end
