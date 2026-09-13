defmodule PhoenixKit.Modules.Publishing.Web.Controller.PostLinksTest do
  @moduledoc """
  End-to-end coverage for `[[post:UUID|Alias]]` publication mentions (PR
  #48): resolution to the target's current public URL, degradation for a
  missing/trashed/unpublished target, and that a rename after the render
  cache is warm still resolves fresh (the whole point of resolving AFTER
  the cache instead of baking the href in at render time).

  Async: false — mutates the global publishing settings rows.
  """

  use PhoenixKitPublishing.ConnCase, async: false

  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.DBStorage
  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.Posts
  alias PhoenixKit.Modules.Publishing.Versions
  alias PhoenixKit.Settings

  defp unique_name, do: "post-link-#{System.unique_integer([:positive])}"

  setup do
    {:ok, _} = Settings.update_boolean_setting("publishing_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("publishing_public_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("languages_enabled", false)
    {:ok, _} = Settings.update_setting("content_language", "en")

    {:ok, group} = Groups.add_group(unique_name(), mode: "slug")
    %{slug: group["slug"]}
  end

  describe "a mention of a published post" do
    test "resolves to the target's current public URL", %{conn: conn, slug: slug} do
      {:ok, target} =
        Posts.create_post(slug, %{title: "Target Post", slug: "target-post", content: "Body."})

      :ok = Versions.publish_version(slug, target.uuid, 1)

      {:ok, source} =
        Posts.create_post(slug, %{
          title: "Source Post",
          slug: "source-post",
          content: "See [[post:#{target.uuid}|the target]] for details."
        })

      :ok = Versions.publish_version(slug, source.uuid, 1)

      html = get(conn, "/#{slug}/source-post") |> html_response(200)

      assert html =~ ~s(<a href="/#{slug}/target-post")
      assert html =~ "the target"

      # `link-primary`, not `link-hover` (PR #49): daisyUI's hover-only
      # underline made a mention read as plain prose until the pointer
      # crossed it. These are the same classes add_tailwind_classes puts
      # on an ordinary in-body anchor, and this pass runs after it, so
      # they have to be inlined here — a revert shows up as a silent
      # styling regression, not a failure, without this assertion.
      assert html =~ ~s(class="link link-primary publishing-post-link")
      refute html =~ "link-hover publishing-post-link"
    end

    test "a token with no alias uses the target's current title", %{conn: conn, slug: slug} do
      {:ok, target} =
        Posts.create_post(slug, %{title: "Untitled Alias Target", slug: "uat", content: "Body."})

      :ok = Versions.publish_version(slug, target.uuid, 1)

      {:ok, source} =
        Posts.create_post(slug, %{
          title: "Source Bare",
          slug: "source-bare",
          content: "See [[post:#{target.uuid}]] for details."
        })

      :ok = Versions.publish_version(slug, source.uuid, 1)

      html = get(conn, "/#{slug}/source-bare") |> html_response(200)
      assert html =~ "Untitled Alias Target"
    end

    test "a renamed target still resolves after the render cache is warm", %{
      conn: conn,
      slug: slug
    } do
      {:ok, target} =
        Posts.create_post(slug, %{title: "Movable Target", slug: "movable", content: "Body."})

      :ok = Versions.publish_version(slug, target.uuid, 1)

      {:ok, source} =
        Posts.create_post(slug, %{
          title: "Source Cached",
          slug: "source-cached",
          content: "See [[post:#{target.uuid}|movable target]] for details."
        })

      :ok = Versions.publish_version(slug, source.uuid, 1)

      # Warm the render cache.
      first = get(conn, "/#{slug}/source-cached") |> html_response(200)
      assert first =~ ~s(href="/#{slug}/movable")

      {:ok, reloaded} = Publishing.read_post_by_uuid(target.uuid, "en", 1)
      {:ok, _} = Posts.update_post(slug, reloaded, %{"slug" => "movable-renamed"}, %{})

      second = get(conn, "/#{slug}/source-cached") |> html_response(200)
      assert second =~ ~s(href="/#{slug}/movable-renamed")
      refute second =~ ~s(href="/#{slug}/movable")
    end
  end

  describe "a mention that can't resolve to a live target" do
    test "a missing post degrades to plain text, never a dead link", %{conn: conn, slug: slug} do
      missing_uuid = "018e3c4a-9f6b-7890-abcd-ef1234567890"

      {:ok, source} =
        Posts.create_post(slug, %{
          title: "Dangling Source",
          slug: "dangling-source",
          content: "See [[post:#{missing_uuid}|a ghost]] for details."
        })

      :ok = Versions.publish_version(slug, source.uuid, 1)

      html = get(conn, "/#{slug}/dangling-source") |> html_response(200)

      refute html =~ "<a href=\"\""
      assert html =~ "a ghost"
      refute html =~ missing_uuid
    end

    test "an unpublished target degrades to plain text", %{conn: conn, slug: slug} do
      {:ok, target} =
        Posts.create_post(slug, %{title: "Draft Target", slug: "draft-target", content: "Body."})

      # Deliberately not published.

      {:ok, source} =
        Posts.create_post(slug, %{
          title: "Points At Draft",
          slug: "points-at-draft",
          content: "See [[post:#{target.uuid}|the draft]] for details."
        })

      :ok = Versions.publish_version(slug, source.uuid, 1)

      html = get(conn, "/#{slug}/points-at-draft") |> html_response(200)

      assert html =~ "the draft"
      refute html =~ ~s(href="/#{slug}/draft-target")
    end

    test "a trashed target degrades to plain text", %{conn: conn, slug: slug} do
      {:ok, target} =
        Posts.create_post(slug, %{
          title: "Soon Trashed",
          slug: "soon-trashed",
          content: "Body."
        })

      :ok = Versions.publish_version(slug, target.uuid, 1)
      {:ok, _} = Posts.trash_post(slug, target.uuid)

      {:ok, source} =
        Posts.create_post(slug, %{
          title: "Points At Trashed",
          slug: "points-at-trashed",
          content: "See [[post:#{target.uuid}|the trashed one]] for details."
        })

      :ok = Versions.publish_version(slug, source.uuid, 1)

      html = get(conn, "/#{slug}/points-at-trashed") |> html_response(200)

      assert html =~ "the trashed one"
      refute html =~ ~s(href="/#{slug}/soon-trashed")
    end

    test "a scheduled target degrades to plain text and leaks no URL", %{conn: conn, slug: slug} do
      # Status alone said "published" for an embargoed timestamp post, so a
      # mention linked it — handing out the not-yet-live URL (its date) to
      # every reader of the source. The public gate is status AND not
      # scheduled ahead; the link resolver must apply the same gate.
      {:ok, ts_group} = Groups.add_group(unique_name(), mode: "timestamp")
      ts_slug = ts_group["slug"]

      {:ok, target} = Posts.create_post(ts_slug, %{title: "Embargoed", content: "Body."})

      future = Date.add(Date.utc_today(), 30)

      {:ok, _} =
        target.uuid
        |> DBStorage.get_post_by_uuid()
        |> Ecto.Changeset.change(post_date: future)
        |> PhoenixKit.RepoHelper.repo().update()

      :ok = Versions.publish_version(ts_slug, target.uuid, 1)

      {:ok, source} =
        Posts.create_post(slug, %{
          title: "Points At Embargo",
          slug: "points-at-embargo",
          content: "See [[post:#{target.uuid}|the embargoed one]] for details."
        })

      :ok = Versions.publish_version(slug, source.uuid, 1)

      html = get(conn, "/#{slug}/points-at-embargo") |> html_response(200)

      assert html =~ "the embargoed one"
      refute html =~ "publishing-post-link"
      refute html =~ Date.to_iso8601(future)
    end

    test "an unpublished target with no alias renders nothing, not its draft title", %{
      conn: conn,
      slug: slug
    } do
      {:ok, target} =
        Posts.create_post(slug, %{title: "Secret Draft Title", slug: "secret", content: "Body."})

      {:ok, source} =
        Posts.create_post(slug, %{
          title: "Bare Mention Of Draft",
          slug: "bare-mention-of-draft",
          content: "Before [[post:#{target.uuid}]] after."
        })

      :ok = Versions.publish_version(slug, source.uuid, 1)

      html = get(conn, "/#{slug}/bare-mention-of-draft") |> html_response(200)

      refute html =~ "Secret Draft Title"
      refute html =~ "[[post:"
      assert html =~ "Before"
    end

    test "the token's UUID may be written in either hex case", %{conn: conn, slug: slug} do
      {:ok, target} =
        Posts.create_post(slug, %{title: "Cased Target", slug: "cased-target", content: "Body."})

      :ok = Versions.publish_version(slug, target.uuid, 1)

      {:ok, source} =
        Posts.create_post(slug, %{
          title: "Upper Source",
          slug: "upper-source",
          content: "See [[post:#{String.upcase(target.uuid)}|shouted]] for details."
        })

      :ok = Versions.publish_version(slug, source.uuid, 1)

      html = get(conn, "/#{slug}/upper-source") |> html_response(200)
      assert html =~ ~s(<a href="/#{slug}/cased-target")
      assert html =~ "shouted"
    end
  end

  describe "resolution cost" do
    @query_event [:phoenix_kit_publishing, :test, :repo, :query]

    def handle_query(_event, _measurements, _meta, pid), do: send(pid, :query)

    test "the number of queries does not grow with the number of mentions", %{slug: slug} do
      # Mentions resolve AFTER the render cache, on every public request —
      # a per-target read (~6 queries each, before) made every mention a
      # standing tax on the page. The resolver is batched: N targets cost
      # the same as one.
      uuids =
        for n <- 1..4 do
          {:ok, post} =
            Posts.create_post(slug, %{title: "Target #{n}", slug: "target-#{n}", content: "x"})

          :ok = Versions.publish_version(slug, post.uuid, 1)
          post.uuid
        end

      # Warm any settings/language caches so both measurements see the same
      # fixed cost.
      Posts.resolve_link_targets(Enum.take(uuids, 1), "en")

      handler_id = {__MODULE__, make_ref()}
      :ok = :telemetry.attach(handler_id, @query_event, &__MODULE__.handle_query/4, self())

      try do
        one = Posts.resolve_link_targets(Enum.take(uuids, 1), "en")
        queries_for_one = drain_query_count()

        four = Posts.resolve_link_targets(uuids, "en")
        queries_for_four = drain_query_count()

        assert map_size(one) == 1
        assert map_size(four) == 4
        assert queries_for_four == queries_for_one
      after
        :telemetry.detach(handler_id)
      end
    end

    defp drain_query_count(count \\ 0) do
      receive do
        :query -> drain_query_count(count + 1)
      after
        0 -> count
      end
    end
  end

  describe "excerpts and feeds" do
    test "a listing excerpt reduces the token to its visible text", %{conn: conn, slug: slug} do
      {:ok, target} =
        Posts.create_post(slug, %{title: "Excerpt Target", slug: "excerpt-target", content: "x"})

      :ok = Versions.publish_version(slug, target.uuid, 1)

      {:ok, source} =
        Posts.create_post(slug, %{
          title: "Excerpt Source",
          slug: "excerpt-source",
          content: "Intro text mentions [[post:#{target.uuid}|a link]] mid-sentence."
        })

      :ok = Versions.publish_version(slug, source.uuid, 1)

      html = get(conn, "/#{slug}") |> html_response(200)

      refute html =~ "[[post:"
      assert html =~ "a link"
    end
  end
end
