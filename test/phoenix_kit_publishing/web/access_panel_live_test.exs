defmodule PhoenixKit.Modules.Publishing.Web.AccessPanelLiveTest do
  @moduledoc """
  The Access panel in the editor and on the group edit page, and the lock
  badge + "Protected posts only" filter in the admin listing.
  """

  use PhoenixKitPublishing.LiveCase

  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.PostAccess
  alias PhoenixKit.Modules.Publishing.Posts
  alias PhoenixKit.Modules.Publishing.Versions
  alias PhoenixKit.Modules.Publishing.Web.Components.AccessPanel
  alias PhoenixKit.Settings

  setup do
    {:ok, _} = Settings.update_boolean_setting("languages_enabled", false)
    {:ok, group} = Groups.add_group("Panel #{System.unique_integer([:positive])}", mode: "slug")

    {:ok, post} =
      Posts.create_post(group["slug"], %{
        title: "Client report",
        slug: "client-report",
        content: "x"
      })

    %{group: group, post: post}
  end

  defp editor(conn, group, post) do
    {:ok, view, _html} =
      conn
      |> put_test_scope(fake_scope())
      |> live("/admin/publishing/#{group["slug"]}/#{post.uuid}/edit")

    view
  end

  test "the editor shows the panel and adds a rule", %{conn: conn, group: group, post: post} do
    view = editor(conn, group, post)
    assert has_element?(view, "#post-access-panel [data-access-summary]", "Public")

    view |> element("#post-access-panel button[phx-value-kind=signed_in]") |> render_click()
    view |> form("#post-access-panel-add") |> render_submit()

    assert PostAccess.protected?(post.uuid)
    assert has_element?(view, "#post-access-panel [data-access-rule=signed_in]")
    assert has_element?(view, "#post-access-panel [data-access-summary]", "signed-in readers")
  end

  test "a group-only event sent to a post's panel changes nothing and crashes nothing", %{
    conn: conn,
    group: group,
    post: post
  } do
    view = editor(conn, group, post)

    for event <- ["apply_defaults", "preview_apply"] do
      view |> with_target("#post-access-panel") |> render_click(event, %{})
    end

    assert Process.alive?(view.pid)
    assert has_element?(view, "#post-access-panel [data-access-summary]", "Public")
  end

  test "a new password can lift the current end date with the No end date box", %{
    conn: conn,
    group: group,
    post: post
  } do
    {:ok, _} =
      PostAccess.set_password({:post, post.uuid}, "first one", %{"expires_at" => "2099-01-01"})

    view = editor(conn, group, post)
    view |> element("#post-access-panel button[phx-value-kind=password]") |> render_click()
    assert has_element?(view, "#post-access-panel [data-no-end-date]")

    view
    |> form("#post-access-panel-add",
      rule: %{"password" => "second one", "expires_at" => "", "no_end_date" => "true"}
    )
    |> render_submit()

    [rule] = Enum.filter(PostAccess.list_rules({:post, post.uuid}), &(&1.kind == "password"))
    assert rule.expires_at == nil
  end

  test "a role rule naming a role that no longer exists says so", %{post: post} do
    gone = "019cce93-0000-7000-8000-00000000dead"

    {:ok, _} =
      PostAccess.add_rule({:post, post.uuid}, %{"kind" => "role", "role_uuids" => [gone]})

    html =
      render_component(AccessPanel,
        id: "post-access-panel",
        owner: {:post, post.uuid},
        scope: fake_scope()
      )

    assert html =~ "a deleted role"
    refute html =~ "Roles: ?"
  end

  test "a secret link is shown once, with its key", %{conn: conn, group: group, post: post} do
    view = editor(conn, group, post)

    view |> element("#post-access-panel button[phx-value-kind=token]") |> render_click()

    view
    |> form("#post-access-panel-add", %{"rule" => %{"note" => "ACME"}})
    |> render_submit()

    assert has_element?(view, "#post-access-panel [data-new-link] input[value*='access_token=']")
    [rule] = PostAccess.list_rules({:post, post.uuid})
    assert rule.kind == "token" and rule.note == "ACME"

    view |> element("#post-access-panel button[phx-click=dismiss_link]") |> render_click()
    refute has_element?(view, "#post-access-panel [data-new-link]")

    view |> element("#post-access-panel button[phx-click=revoke_link]") |> render_click()
    assert PostAccess.get_rule(rule.uuid).revoked_at
  end

  test "a too-short password is refused with a message", %{conn: conn, group: group, post: post} do
    view = editor(conn, group, post)
    view |> element("#post-access-panel button[phx-value-kind=password]") |> render_click()

    html =
      view
      |> form("#post-access-panel-add", %{"rule" => %{"password" => "abc"}})
      |> render_submit()

    assert html =~ "at least 4 characters"
    refute PostAccess.protected?(post.uuid)
  end

  test "a reader without the publishing permission cannot change access", %{
    group: group,
    post: post
  } do
    {:ok, _} = PostAccess.add_rule({:post, post.uuid}, %{"kind" => "signed_in"})
    [rule] = PostAccess.list_rules({:post, post.uuid})

    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        owner: {:post, post.uuid},
        scope: fake_scope(permissions: []),
        rules: [rule]
      }
    }

    {:noreply, _} =
      AccessPanel.handle_event(
        "delete_rule",
        %{"uuid" => rule.uuid},
        socket
      )

    assert PostAccess.protected?(post.uuid)
    _ = group
  end

  test "the admin listing marks protected posts and filters them", %{
    conn: conn,
    group: group,
    post: post
  } do
    {:ok, open} =
      Posts.create_post(group["slug"], %{title: "Open note", slug: "open-note", content: "y"})

    :ok = Versions.publish_version(group["slug"], open.uuid, 1)
    :ok = Versions.publish_version(group["slug"], post.uuid, 1)
    {:ok, _} = PostAccess.add_rule({:post, post.uuid}, %{"kind" => "signed_in"})

    {:ok, view, _html} =
      conn
      |> put_test_scope(fake_scope())
      |> live("/admin/publishing/#{group["slug"]}")

    assert has_element?(view, "[data-access-lock]")

    html = view |> element("[data-protected-filter] input") |> render_click()
    assert html =~ "Client report"
    refute html =~ "Open note"
  end

  test "the group page holds the defaults and applies them on request", %{
    conn: conn,
    group: group,
    post: post
  } do
    {:ok, view, _html} =
      conn
      |> put_test_scope(fake_scope())
      |> live("/admin/publishing/edit-group/#{group["slug"]}")

    assert has_element?(view, "#group-access-panel", "Default access for new posts")
    refute has_element?(view, "#group-access-panel button[phx-value-kind=token]")

    view |> element("#group-access-panel button[phx-value-kind=signed_in]") |> render_click()
    view |> form("#group-access-panel-add") |> render_submit()

    view
    |> element("#group-access-panel button[phx-click=preview_apply]")
    |> render_click()

    assert has_element?(view, "#group-access-panel [data-apply-confirm]", "Change 1 post")

    view |> form("#group-access-panel-apply") |> render_submit()
    assert PostAccess.protected?(post.uuid)

    {:ok, new_post} = Posts.create_post(group["slug"], %{title: "Next week", slug: "next-week"})
    assert PostAccess.protected?(new_post.uuid)
  end
end
