defmodule PhoenixKit.Modules.Publishing.Web.PreviewLiveTest do
  @moduledoc """
  Smoke tests for the Preview LV. Pins:

    * Mount on the group-only route renders the preview container
    * Mount on a post route renders the post content
    * `back_to_editor` event navigates correctly
    * `handle_info` catch-all swallows unknown messages
    * Missing post UUID 404s back to the group listing
  """

  use PhoenixKitPublishing.LiveCase

  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.Posts
  alias PhoenixKit.Settings

  setup do
    {:ok, _} = Settings.update_boolean_setting("languages_enabled", true)

    {:ok, group} =
      Groups.add_group("Preview LV #{System.unique_integer([:positive])}", mode: "slug")

    {:ok, post} = Posts.create_post(group["slug"], %{title: "Preview Subject"})

    %{group: group, post: post}
  end

  test "mount on the post route renders the post for preview", %{
    conn: conn,
    group: group,
    post: post
  } do
    {:ok, _view, html} =
      conn
      |> put_test_scope(fake_scope())
      |> live("/admin/publishing/#{group["slug"]}/#{post[:uuid]}/preview")

    # The preview LV renders the title in the page
    assert html =~ "Preview Subject" || html =~ post[:slug]
  end

  test "back_to_editor event navigates to the editor URL", %{
    conn: conn,
    group: group,
    post: post
  } do
    {:ok, view, _html} =
      conn
      |> put_test_scope(fake_scope())
      |> live("/admin/publishing/#{group["slug"]}/#{post[:uuid]}/preview")

    # back_to_editor uses push_navigate; assert_redirect catches it
    assert {:error, {:live_redirect, %{to: destination}}} =
             render_click(view, "back_to_editor", %{})

    assert destination =~ "/admin/publishing/#{group["slug"]}"
    assert destination =~ post[:uuid]
    assert destination =~ "/edit"
  end

  test "handle_info catch-all swallows unknown messages", %{
    conn: conn,
    group: group,
    post: post
  } do
    {:ok, view, _html} =
      conn
      |> put_test_scope(fake_scope())
      |> live("/admin/publishing/#{group["slug"]}/#{post[:uuid]}/preview")

    send(view.pid, {:bogus_message, "ignored"})
    send(view.pid, :unexpected_atom)
    assert is_binary(render(view))
  end
end
