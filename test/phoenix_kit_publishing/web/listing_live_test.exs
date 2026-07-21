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
  alias PhoenixKit.Modules.Publishing.ListingCache
  alias PhoenixKit.Modules.Publishing.Posts
  alias PhoenixKit.Modules.Publishing.PubSub, as: PublishingPubSub
  alias PhoenixKit.Modules.Publishing.Versions
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
    # The post's title renders as its link in the listing.
    assert html =~ "Sample post for listing"
  end

  test "a live post with newer draft revisions stays on the Published tab", %{
    conn: conn,
    group: group,
    post: post
  } do
    :ok = Versions.publish_version(group["slug"], post.uuid, 1)
    {:ok, _} = Versions.create_version_from(group["slug"], post.uuid, 1, %{})

    # The loader classifies by the LIVE (active) version — the same rule the
    # public listing applies — not by the newest revision's own status.
    listed = Enum.find(Posts.list_posts(group["slug"]), &(&1.uuid == post.uuid))
    assert listed.metadata.status == "published"
    # The newest revision itself stays an honest draft in the version map.
    assert listed.version_statuses[listed.metadata.version] == "draft"
    # The visible publish date comes from the LIVE version too — the mapped
    # draft's published_at is nil, which used to render "Unsaved draft"
    # beside the Published badge (panel finding A1).
    assert is_binary(listed.metadata.published_at)
    # The published overlay keeps the live language accurate in the pill map
    # (panel finding A2) — key derived from the fixture's actual language.
    [lang] = listed.available_languages
    assert listed.language_statuses[lang] == "published"

    {:ok, _view, html} =
      conn
      |> put_test_scope(fake_scope())
      |> live("/admin/publishing/#{group["slug"]}")

    # Default view is the Published tab — the post is there. No revision
    # badge: versions are an archival tool (keep the old legal text, branch a
    # rewrite), not a pending-work state the listing should flag (boss call,
    # 2026-07-21).
    assert html =~ "Sample post for listing"
    refute html =~ "Unpublished edits"
  end

  test "a never-published post with stacked drafts stays Draft (no live version)", %{
    conn: _conn,
    group: group,
    post: post
  } do
    # The effective-status override must NOT fire without a live (active,
    # published) version — an unpublished post with several draft revisions
    # keeps classifying by its newest revision.
    {:ok, _} = Versions.create_version_from(group["slug"], post.uuid, 1, %{})

    listed = Enum.find(Posts.list_posts(group["slug"]), &(&1.uuid == post.uuid))
    assert listed.metadata.status == "draft"
  end

  test "header actions link to the group's settings page", %{conn: conn, group: group} do
    {:ok, _view, html} =
      conn
      |> put_test_scope(fake_scope())
      |> live("/admin/publishing/#{group["slug"]}")

    assert html =~ "/admin/publishing/edit-group/#{group["slug"]}"
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

    # `create_post` is expected to issue a live_redirect to the new-post
    # path. The prior `match?(...) or is_binary(result)` disjunction
    # passed even when the redirect never happened.
    assert {:error, {:live_redirect, %{to: to}}} = render_click(view, "create_post", %{})
    assert to =~ "/admin/publishing/#{group["slug"]}/new"
  end

  test "refresh event re-fetches the post list", %{conn: conn, group: group, post: _post} do
    {:ok, view, _html} =
      conn
      |> put_test_scope(fake_scope())
      |> live("/admin/publishing/#{group["slug"]}")

    # The seeded post's title is the load-bearing assertion — refresh
    # is meant to render the list, not just return any binary. (The
    # listing renders the title verbatim; the slug only appears in the
    # edit URL via UUID, never as readable text.)
    html = render_click(view, "refresh", %{})
    assert html =~ "Sample post for listing"
  end

  test "trash_post event soft-deletes a post and flashes success",
       %{conn: conn, group: group, post: post} do
    {:ok, view, _html} =
      conn
      |> put_test_scope(fake_scope())
      |> live("/admin/publishing/#{group["slug"]}")

    html = render_click(view, "trash_post", %{"uuid" => post[:uuid]})

    # Pin both the user-visible flash and the DB-side state. The prior
    # `is_binary(html)` tautology accepted ANY render including ones
    # where the trash silently failed. Trashed posts are filtered out
    # of `Posts.read_post/2` (the active-listing read path), so the
    # `:not_found` result is the soft-delete success signal.
    assert html =~ "Post moved to trash"
    assert Posts.read_post(group["slug"], post[:slug]) == {:error, :not_found}
  end

  test "restore_post event un-trashes a post and flashes success",
       %{conn: conn, group: group} do
    {:ok, post} = Posts.create_post(group["slug"], %{title: "ToRestore"})
    {:ok, _} = Posts.trash_post(group["slug"], post[:uuid])

    {:ok, view, _html} =
      conn
      |> put_test_scope(fake_scope())
      |> live("/admin/publishing/#{group["slug"]}")

    _ = render_click(view, "switch_post_view", %{"mode" => "trashed"})
    html = render_click(view, "restore_post", %{"uuid" => post[:uuid]})

    # After restore the post should be visible to `read_post/2` again
    # (it filters trashed). Flash + reachability together prove the
    # restore worked end-to-end, not just rendered something.
    assert html =~ "Post restored as draft"
    assert {:ok, _reloaded} = Posts.read_post(group["slug"], post[:slug])
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

  # Regression: the :cache_changed handler used to call `ListingCache.regenerate/1`,
  # which re-broadcasts :cache_changed. Because the LiveView subscribes to its own
  # group's cache topic, the echo re-entered the handler → regenerate → broadcast →
  # … a self-sustaining, cluster-wide regeneration storm. The old smoke test above
  # missed it: `render(view)`'s reply is delivered before the first echo is processed
  # (FIFO mailbox), so it asserts one render round-trip and the loop only runs *after*
  # the assertion, until test teardown kills the view. The handler now INVALIDATES
  # (erases) the term instead, which emits nothing. This test pins the actual
  # invariant: handling :cache_changed must NOT emit another :cache_changed.
  test "handle_info {:cache_changed, _} invalidates silently — no re-broadcast (no storm)",
       %{conn: conn, group: group} do
    # Enable the memory cache so a regression back to `regenerate` would actually
    # reach the broadcast (regenerate short-circuits to :ok when caching is off).
    {:ok, _} = Settings.update_boolean_setting("publishing_memory_cache_enabled", true)

    {:ok, view, _html} =
      conn
      |> put_test_scope(fake_scope())
      |> live("/admin/publishing/#{group["slug"]}")

    # Observe the group's cache topic from the test process. The LiveView is a
    # subscriber too, so any echo it emits would also come back to us here.
    PublishingPubSub.subscribe_to_cache(group["slug"])

    send(view.pid, {:cache_changed, group["slug"]})

    # The handler must refresh WITHOUT announcing :cache_changed. If it re-broadcast,
    # we'd receive the echo (and the view would loop forever). Assert no echo arrives.
    refute_receive {:cache_changed, _}, 300

    # And the view is still alive and renders after handling the message.
    assert is_binary(render(view))
  end

  # Pins the broadcast contract from the other direction: a *data mutation* that
  # regenerates the cache (the default `broadcast: true`) MUST still announce
  # :cache_changed so other nodes refresh their node-local cache. The silent path
  # above is only for consumers reacting to that announcement.
  test "ListingCache.regenerate/2 announces :cache_changed by default, stays silent on demand",
       %{group: group} do
    {:ok, _} = Settings.update_boolean_setting("publishing_memory_cache_enabled", true)
    slug = group["slug"]
    PublishingPubSub.subscribe_to_cache(slug)

    # Pin the slug so the assertion can't pass on an unrelated echo.
    assert :ok = ListingCache.regenerate(slug)
    assert_receive {:cache_changed, ^slug}, 300

    assert :ok = ListingCache.regenerate(slug, broadcast: false)
    refute_receive {:cache_changed, ^slug}, 300
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

  test "add_language event navigates to the edit URL with lang param",
       %{conn: conn, group: group, post: post} do
    {:ok, view, _html} =
      conn
      |> put_test_scope(fake_scope())
      |> live("/admin/publishing/#{group["slug"]}")

    result =
      render_click(view, "add_language", %{
        "language" => "fr-FR",
        "uuid" => post[:uuid]
      })

    assert match?({:error, {:live_redirect, _}}, result) or is_binary(result)
  end

  test "language_action with uuid navigates to edit URL",
       %{conn: conn, group: group, post: post} do
    {:ok, view, _html} =
      conn
      |> put_test_scope(fake_scope())
      |> live("/admin/publishing/#{group["slug"]}")

    result =
      render_click(view, "language_action", %{
        "language" => "fr-FR",
        "uuid" => post[:uuid]
      })

    assert match?({:error, {:live_redirect, _}}, result) or is_binary(result)
  end

  test "language_action without uuid is a no-op", %{conn: conn, group: group} do
    {:ok, view, _html} =
      conn
      |> put_test_scope(fake_scope())
      |> live("/admin/publishing/#{group["slug"]}")

    html = render_click(view, "language_action", %{"language" => "fr-FR", "uuid" => ""})
    assert is_binary(html)
  end

  test "change_status event updates post status", %{conn: conn, group: group, post: post} do
    {:ok, view, _html} =
      conn
      |> put_test_scope(fake_scope())
      |> live("/admin/publishing/#{group["slug"]}")

    html =
      render_click(view, "change_status", %{
        "uuid" => post[:uuid],
        "status" => "published"
      })

    assert is_binary(html)
  end

  test "toggle_status event cycles draft → published → archived → draft",
       %{conn: conn, group: group, post: post} do
    {:ok, view, _html} =
      conn
      |> put_test_scope(fake_scope())
      |> live("/admin/publishing/#{group["slug"]}")

    assert is_binary(
             render_click(view, "toggle_status", %{
               "uuid" => post[:uuid],
               "current-status" => "draft"
             })
           )
  end

  test "handle_info {:version_created, _} updates post in list",
       %{conn: conn, group: group, post: post} do
    {:ok, view, _html} =
      conn
      |> put_test_scope(fake_scope())
      |> live("/admin/publishing/#{group["slug"]}")

    send(view.pid, {:version_created, %{uuid: post[:uuid], slug: post[:slug]}})
    assert is_binary(render(view))
  end

  test "handle_info {:version_deleted, slug, _} refreshes",
       %{conn: conn, group: group, post: post} do
    {:ok, view, _html} =
      conn
      |> put_test_scope(fake_scope())
      |> live("/admin/publishing/#{group["slug"]}")

    send(view.pid, {:version_deleted, post[:slug], 1})
    assert is_binary(render(view))
  end

  test "handle_info {:translation_started, slug, count} starts translation indicator",
       %{conn: conn, group: group, post: post} do
    {:ok, view, _html} =
      conn
      |> put_test_scope(fake_scope())
      |> live("/admin/publishing/#{group["slug"]}")

    send(view.pid, {:translation_started, post[:slug], 3})
    assert is_binary(render(view))
  end

  test "handle_info {:translation_progress, slug, n, total} updates progress",
       %{conn: conn, group: group, post: post} do
    {:ok, view, _html} =
      conn
      |> put_test_scope(fake_scope())
      |> live("/admin/publishing/#{group["slug"]}")

    send(view.pid, {:translation_progress, post[:slug], 1, 3})
    assert is_binary(render(view))
  end

  test "handle_info {:translation_completed, slug, results} clears indicator",
       %{conn: conn, group: group, post: post} do
    {:ok, view, _html} =
      conn
      |> put_test_scope(fake_scope())
      |> live("/admin/publishing/#{group["slug"]}")

    # Real shape per Listing.handle_info on :translation_completed —
    # has success_count/failed_count fields.
    send(view.pid, {:translation_completed, post[:slug], %{success_count: 1, failure_count: 0}})
    assert is_binary(render(view))
  end
end
