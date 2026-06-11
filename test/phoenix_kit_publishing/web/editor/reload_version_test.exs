defmodule PhoenixKit.Modules.Publishing.Web.Editor.ReloadVersionTest do
  @moduledoc """
  Regression test for H9 — editor reload paths must stay pinned to the version
  the editor is on, not jump to the latest. `re_read_post/3` defaults its version
  to the socket's `current_version`; without that, reloading a post with newer
  versions would load the wrong version's content under a URL claiming the pinned
  one and misdirect the next save.
  """

  use PhoenixKit.DataCase, async: true

  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.DBStorage
  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.Posts
  alias PhoenixKit.Modules.Publishing.Web.Editor.Persistence

  test "reload_post stays pinned to current_version, not the latest version (H9)" do
    {:ok, group} =
      Groups.add_group("Reload #{System.unique_integer([:positive])}", mode: "slug")

    {:ok, post} = Posts.create_post(group["slug"], %{title: "Reload Me", content: "v1 body"})

    # A second (latest) version — left unpublished, so the post has no active
    # version and a version-less read resolves to the LATEST (v2). This is the
    # exact condition under which the un-pinned reload loaded the wrong version.
    {:ok, _v2} = DBStorage.create_version_from(post[:uuid], 1)

    lang = post[:language]
    {:ok, v1_post} = Publishing.read_post_by_uuid(post[:uuid], lang, 1)
    assert v1_post.version == 1

    socket = %Phoenix.LiveView.Socket{
      id: "reload-test",
      assigns: %{
        __changed__: %{},
        flash: %{},
        group_slug: group["slug"],
        current_language: lang,
        current_version: 1,
        post: v1_post,
        form: %{},
        content: v1_post.content
      }
    }

    result = Persistence.reload_post(socket)

    # Pinned to v1. Before the fix, the version-less re-read resolved to the
    # latest (v2) and the editor silently switched versions.
    assert result.assigns.post.version == 1
  end
end
