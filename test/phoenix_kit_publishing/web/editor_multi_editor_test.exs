defmodule PhoenixKit.Modules.Publishing.Web.EditorMultiEditorTest do
  @moduledoc """
  Two people in the same post at once: the first holds the edit lock, the
  second watches read-only, and the owner's typing reaches the watcher live.

  Worth pinning because the content path only recently learned to broadcast
  at all — body edits arrive as a process message from the MarkdownEditor
  component, and that handler used to skip the whole collaborative pipeline
  (no broadcast, no activity refresh), so a spectator saw nothing while the
  owner's own lock quietly expired under them.
  """

  use PhoenixKitPublishing.LiveCase, async: false

  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.Posts

  defp assigns_of(view) do
    view.pid |> :sys.get_state() |> get_in([Access.key(:socket), Access.key(:assigns)])
  end

  setup do
    {:ok, group} = Groups.add_group("multi-#{System.unique_integer([:positive])}", mode: "slug")
    {:ok, post} = Posts.create_post(group["slug"], %{title: "Shared", slug: "shared"})
    %{group: group, post: post}
  end

  defp open_editor(user_uuid, email, group, post) do
    {:ok, view, _html} =
      build_conn()
      |> put_test_scope(fake_scope(user_uuid: user_uuid, email: email))
      |> live("/admin/publishing/#{group["slug"]}/#{post[:uuid]}/edit")

    view
  end

  test "the second editor watches read-only while the first keeps the lock", %{
    group: group,
    post: post
  } do
    owner = open_editor("019cce93-0000-7000-8000-00000000aaa1", "owner@example.com", group, post)
    _ = render(owner)

    watcher =
      open_editor("019cce93-0000-7000-8000-00000000bbb2", "watcher@example.com", group, post)

    _ = render(watcher)
    _ = render(owner)

    assert assigns_of(owner)[:lock_owner?] == true
    refute assigns_of(owner)[:readonly?]

    # The watcher must not be able to type over the owner.
    assert assigns_of(watcher)[:lock_owner?] == false
    assert assigns_of(watcher)[:readonly?] == true

    # And the owner is told they aren't alone.
    assert assigns_of(owner)[:other_viewers] != []
  end

  test "the owner's body typing reaches the watcher", %{group: group, post: post} do
    owner = open_editor("019cce93-0000-7000-8000-00000000aaa1", "owner@example.com", group, post)
    _ = render(owner)

    watcher =
      open_editor("019cce93-0000-7000-8000-00000000bbb2", "watcher@example.com", group, post)

    _ = render(watcher)

    # Exactly how the MarkdownEditor component reports an edit.
    send(
      owner.pid,
      {:leaf_changed, %{editor_id: "content-editor", markdown: "Live from the owner.", html: ""}}
    )

    _ = render(owner)
    _ = render(watcher)

    assert assigns_of(owner)[:content] == "Live from the owner."
    assert assigns_of(watcher)[:content] == "Live from the owner."

    # The owner's typing also counts as activity, which is what keeps their
    # lock from lapsing mid-session.
    assert is_integer(assigns_of(owner)[:last_activity_at])
  end

  test "a watcher's own content message is ignored, not applied back", %{
    group: group,
    post: post
  } do
    owner = open_editor("019cce93-0000-7000-8000-00000000aaa1", "owner@example.com", group, post)
    _ = render(owner)

    watcher =
      open_editor("019cce93-0000-7000-8000-00000000bbb2", "watcher@example.com", group, post)

    _ = render(watcher)

    send(
      watcher.pid,
      {:leaf_changed, %{editor_id: "content-editor", markdown: "Spectator scribble.", html: ""}}
    )

    _ = render(watcher)
    _ = render(owner)

    # A read-only session must never push its buffer at the owner.
    refute assigns_of(owner)[:content] == "Spectator scribble."
  end
end
