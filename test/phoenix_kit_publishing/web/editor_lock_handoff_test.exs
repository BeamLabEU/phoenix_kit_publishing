defmodule PhoenixKit.Modules.Publishing.Web.EditorLockHandoffTest do
  @moduledoc """
  What happens to unsaved work when the person holding the edit lock vanishes.

  A watcher mirrors the owner keystroke by keystroke, so between the owner's
  last autosave and their next one the watcher's socket is the only copy of
  that text outside the owner's browser. Presence then promotes the watcher —
  and the promotion path used to re-read the row and overwrite everything it
  was already showing. The writer saw their colleague's paragraph on screen,
  became the editor, and watched it revert to the older saved copy with no
  error and nothing to undo.

  Both directions are pinned here, because the fix is only correct if it still
  reloads when there is nothing newer to keep.
  """

  use PhoenixKitPublishing.LiveCase, async: false

  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.Posts
  alias PhoenixKitPublishing.Test.Repo, as: TestRepo

  @owner_uuid "019cce93-0000-7000-8000-00000000aaa1"
  @watcher_uuid "019cce93-0000-7000-8000-00000000bbb2"

  # The rest of the suite runs on a scope whose user has no row behind it,
  # which is fine while nothing is written. Here the recovered text has to
  # reach the database, and the save stamps updated_by_uuid — so these two
  # need to actually exist or the write dies on a foreign key.
  defp insert_user(uuid, email) do
    TestRepo.query!(
      """
      INSERT INTO phoenix_kit_users (uuid, email, hashed_password, inserted_at, updated_at)
      VALUES ($1::uuid, $2, 'x', now(), now())
      ON CONFLICT (email) DO NOTHING
      """,
      [Ecto.UUID.dump!(uuid), email]
    )
  end

  defp assigns_of(view) do
    view.pid |> :sys.get_state() |> get_in([Access.key(:socket), Access.key(:assigns)])
  end

  setup do
    insert_user(@owner_uuid, "handoff-owner@example.com")
    insert_user(@watcher_uuid, "handoff-watcher@example.com")

    {:ok, group} = Groups.add_group("handoff-#{System.unique_integer([:positive])}", mode: "slug")

    {:ok, post} =
      Posts.create_post(group["slug"], %{
        title: "Shared",
        slug: "shared",
        content: "The saved copy."
      })

    %{group: group, post: post}
  end

  defp open_editor(user_uuid, email, group, post) do
    {:ok, view, _html} =
      build_conn()
      |> put_test_scope(fake_scope(user_uuid: user_uuid, email: email))
      |> live("/admin/publishing/#{group["slug"]}/#{post[:uuid]}/edit")

    view
  end

  # Exactly the shape PubSub delivers to a spectator when the owner types.
  defp owner_typed(watcher, text) do
    assigns = assigns_of(watcher)

    send(
      watcher.pid,
      {:editor_form_change, assigns[:form_key],
       %{type: :content, data: %{content: text, form: assigns[:form]}}, "owner-socket-id"}
    )

    _ = render(watcher)
    watcher
  end

  # Drop the owner without letting them save on the way out — a closed laptop,
  # a dead tab. Presence untracks when the process goes down and broadcasts the
  # diff that promotes the watcher.
  #
  # Stopped rather than killed on purpose: LiveViewTest links the view to its
  # client proxy and the proxy to the test, so `Process.exit(:kill)` takes the
  # test down with it. A `:normal` stop leaves presence with the same work to
  # do — the process is gone either way, and it never ran a save.
  defp abandon(view) do
    ref = Process.monitor(view.pid)
    GenServer.stop(view.pid, :normal)
    assert_receive {:DOWN, ^ref, :process, _, _}, 2_000
  end

  test "a promoted watcher keeps the unsaved text it was already showing", %{
    group: group,
    post: post
  } do
    owner = open_editor(@owner_uuid, "handoff-owner@example.com", group, post)
    _ = render(owner)

    watcher =
      open_editor(@watcher_uuid, "handoff-watcher@example.com", group, post)

    _ = render(watcher)
    assert assigns_of(watcher)[:readonly?] == true

    owner_typed(watcher, "A paragraph that never reached the database.")
    assert assigns_of(watcher)[:content] == "A paragraph that never reached the database."

    abandon(owner)

    # Presence promotes on its own diff; give it a beat to arrive.
    assert eventually(fn -> assigns_of(watcher)[:lock_owner?] == true end)

    after_promotion = assigns_of(watcher)

    # The whole point. Without the fix this reads "The saved copy." — the
    # colleague's paragraph is gone and nobody was told.
    assert after_promotion[:content] == "A paragraph that never reached the database."

    # And it has to be marked as owed to the database, or the recovered text
    # sits in a socket that believes it is already saved and loses it again on
    # the next reload.
    assert after_promotion[:has_pending_changes] == true

    # The marker is consumed by the promotion: this is the promoted user's own
    # work now, not something mirrored from someone else.
    assert after_promotion[:synced_from_owner?] == false
  end

  test "the recovered text is actually written, not just held in memory", %{
    group: group,
    post: post
  } do
    owner = open_editor(@owner_uuid, "handoff-owner@example.com", group, post)
    _ = render(owner)

    watcher =
      open_editor(@watcher_uuid, "handoff-watcher@example.com", group, post)

    _ = render(watcher)
    owner_typed(watcher, "Rescued prose.")

    abandon(owner)
    assert eventually(fn -> assigns_of(watcher)[:lock_owner?] == true end)

    # Promotion arms autosave rather than saving inline, so the proof is that
    # the row catches up on its own.
    assert eventually(
             fn ->
               case Posts.read_post(group["slug"], post[:uuid]) do
                 {:ok, reloaded} -> reloaded.content == "Rescued prose."
                 _ -> false
               end
             end,
             3_000
           )
  end

  test "a watcher with nothing newer still reloads the saved copy on promotion", %{
    group: group,
    post: post
  } do
    owner = open_editor(@owner_uuid, "handoff-owner@example.com", group, post)
    _ = render(owner)

    watcher =
      open_editor(@watcher_uuid, "handoff-watcher@example.com", group, post)

    _ = render(watcher)

    # This watcher never received a live change, so the row is the best copy
    # there is and promotion must go and get it.
    abandon(owner)
    assert eventually(fn -> assigns_of(watcher)[:lock_owner?] == true end)

    after_promotion = assigns_of(watcher)
    assert after_promotion[:content] == "The saved copy."
    assert after_promotion[:has_pending_changes] == false
  end

  test "a save landing after the sync stands the marker down", %{group: group, post: post} do
    owner = open_editor(@owner_uuid, "handoff-owner@example.com", group, post)
    _ = render(owner)

    watcher =
      open_editor(@watcher_uuid, "handoff-watcher@example.com", group, post)

    _ = render(watcher)
    owner_typed(watcher, "Draft text.")
    assert assigns_of(watcher)[:synced_from_owner?] == true

    # Someone saved. The watcher reloads and is back in line with the row, so
    # its buffer is no longer ahead of anything and promotion should trust the
    # database again — otherwise a stale marker would resurrect old text.
    send(watcher.pid, {:editor_saved, assigns_of(watcher)[:form_key], "someone-else"})
    _ = render(watcher)

    assert assigns_of(watcher)[:synced_from_owner?] == false
  end

  defp eventually(fun, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_eventually(fun, deadline)
  end

  defp do_eventually(fun, deadline) do
    cond do
      fun.() -> true
      System.monotonic_time(:millisecond) >= deadline -> false
      true -> Process.sleep(25) && do_eventually(fun, deadline)
    end
  end
end
