defmodule PhoenixKit.Modules.Publishing.Web.Controller.CommentsTest do
  @moduledoc """
  Pins the public comment contract over the optional comments seam: thread +
  form gated on the group flag AND the module, logged-in-only posting, and
  the honeypot / signed-time-trap guards on the POST path.
  """

  # async: false — mutates the global publishing/comments settings rows.
  use PhoenixKitPublishing.ConnCase, async: false

  alias PhoenixKit.Modules.Publishing.Comments, as: PublishingComments
  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.Posts
  alias PhoenixKit.Modules.Publishing.Renderer
  alias PhoenixKit.Modules.Publishing.Versions
  alias PhoenixKit.Settings
  alias PhoenixKitPublishing.Test.Repo, as: TestRepo

  defp unique_name, do: "cmt-#{System.unique_integer([:positive])}"

  setup do
    {:ok, _} = Settings.update_boolean_setting("publishing_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("publishing_public_enabled", true)
    # The comments MODULE's global switch (distinct from the per-group flag,
    # which shares the name but lives in group data).
    {:ok, _} = Settings.update_boolean_setting("comments_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("languages_enabled", false)
    {:ok, _} = Settings.update_setting("content_language", "en")

    {:ok, group} = Groups.add_group(unique_name(), mode: "slug")
    slug = group["slug"]

    {:ok, post} =
      Posts.create_post(slug, %{title: "Discussed", slug: "discussed", content: "Body."})

    :ok = Versions.publish_version(slug, post.uuid, 1)

    # Insert the user row directly — register_user/1 rides the rate-limiter
    # process, which the library test env doesn't start.
    user =
      TestRepo.insert!(%PhoenixKit.Users.Auth.User{
        email: "commenter-#{System.unique_integer([:positive])}@example.com",
        hashed_password: "x",
        first_name: "Casey",
        last_name: "Reader"
      })

    %{slug: slug, post: post, user: user}
  end

  defp aged_token do
    Phoenix.Token.sign(
      PhoenixKitPublishing.Test.Endpoint,
      "pk_pub_comment",
      System.system_time(:second) - 10
    )
  end

  defp login(user) do
    scope = fake_admin_scope(user)
    with_scope(scope)
    :ok
  end

  # A minimal authenticated scope shaped like core's (user + authenticated).
  defp fake_admin_scope(user) do
    %PhoenixKit.Users.Auth.Scope{user: user, authenticated?: true, cached_roles: ["User"]}
  end

  defp post_comment(conn, slug, params) do
    post(conn, "/#{slug}/discussed", params)
  end

  defp base_params(post, content) do
    %{"post_uuid" => post.uuid, "content" => content, "ft" => aged_token(), "website" => ""}
  end

  test "no section while the group flag is off", %{conn: conn, slug: slug} do
    refute get(conn, "/#{slug}/discussed") |> html_response(200) =~ ~s(id="comments")
  end

  test "section renders with a login prompt when logged out", %{conn: conn, slug: slug} do
    {:ok, _} = Groups.update_group(slug, %{"comments_enabled" => "true"})
    html = get(conn, "/#{slug}/discussed") |> html_response(200)

    assert html =~ ~s(id="comments")
    assert html =~ "No comments yet"
    assert html =~ "Log in"
    refute html =~ "<textarea"
  end

  test "logged-out POST is rejected with a flash", %{conn: conn, slug: slug, post: post} do
    {:ok, _} = Groups.update_group(slug, %{"comments_enabled" => "true"})

    conn = post_comment(conn, slug, base_params(post, "Nice try"))
    assert redirected_to(conn) =~ "/#{slug}/discussed"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "log in"
    assert PublishingComments.list(post.uuid) == []
  end

  test "a logged-in reader posts a comment and it renders", %{
    conn: conn,
    slug: slug,
    post: post,
    user: user
  } do
    {:ok, _} = Groups.update_group(slug, %{"comments_enabled" => "true"})
    :ok = login(user)

    conn = post_comment(conn, slug, base_params(post, "Great read, **thanks**!"))
    assert redirected_to(conn) =~ "#comments"

    assert [comment] = PublishingComments.list(post.uuid)
    assert comment.content =~ "Great read"

    html = build_conn() |> get("/#{slug}/discussed") |> html_response(200)
    assert html =~ "1 comment"
    assert html =~ "Great read"
  end

  test "the honeypot swallows bot submissions silently", %{
    conn: conn,
    slug: slug,
    post: post,
    user: user
  } do
    {:ok, _} = Groups.update_group(slug, %{"comments_enabled" => "true"})
    :ok = login(user)

    params = base_params(post, "spam") |> Map.put("website", "https://spam.example")
    conn = post_comment(conn, slug, params)

    assert redirected_to(conn) =~ "/#{slug}/discussed"
    assert PublishingComments.list(post.uuid) == []
  end

  test "a too-fresh or invalid time-trap token is rejected", %{
    conn: conn,
    slug: slug,
    post: post,
    user: user
  } do
    {:ok, _} = Groups.update_group(slug, %{"comments_enabled" => "true"})
    :ok = login(user)

    fresh =
      Phoenix.Token.sign(
        PhoenixKitPublishing.Test.Endpoint,
        "pk_pub_comment",
        System.system_time(:second)
      )

    for bad <- [fresh, "garbage", nil] do
      conn2 = post_comment(conn, slug, %{base_params(post, "hi") | "ft" => bad})
      assert redirected_to(conn2) =~ "/#{slug}/discussed"
    end

    assert PublishingComments.list(post.uuid) == []
  end

  test "an unknown post uuid bounces to the listing", %{
    conn: conn,
    slug: slug,
    post: post,
    user: user
  } do
    {:ok, _} = Groups.update_group(slug, %{"comments_enabled" => "true"})
    :ok = login(user)

    params = %{base_params(post, "hi") | "post_uuid" => Ecto.UUID.generate()}
    conn = post_comment(conn, slug, params)

    assert redirected_to(conn) == "/#{slug}"
  end

  describe "threaded replies" do
    setup %{slug: slug, user: user} do
      {:ok, _} = Groups.update_group(slug, %{"comments_enabled" => "true"})
      :ok = login(user)
      :ok
    end

    test "a reply nests under its parent in the rendered thread", %{
      conn: conn,
      slug: slug,
      post: post,
      user: user
    } do
      {:ok, parent} = PublishingComments.create(post.uuid, user.uuid, "Parent comment")

      conn =
        post_comment(
          conn,
          slug,
          Map.put(base_params(post, "The reply"), "parent_uuid", parent.uuid)
        )

      assert redirected_to(conn) =~ "#comment-#{parent.uuid}"

      page = PublishingComments.for_post_page(post.uuid)
      assert [%{content: "Parent comment", children: [%{content: "The reply"}]}] = page.thread
      assert page.count == 2

      html = build_conn() |> get("/#{slug}/discussed") |> html_response(200)
      assert html =~ "2 comments"
      assert html =~ "The reply"
      # The reply affordance renders for logged-out readers too? No — the
      # details/summary Reply only shows when logged in.
      refute html =~ ">Reply<"
    end

    test "a parent from ANOTHER post is rejected", %{
      conn: conn,
      slug: slug,
      post: post,
      user: user
    } do
      {:ok, other} =
        Posts.create_post(slug, %{title: "Other", slug: "other", content: "Body."})

      :ok = Versions.publish_version(slug, other.uuid, 1)
      {:ok, foreign_parent} = PublishingComments.create(other.uuid, user.uuid, "Elsewhere")

      conn =
        post_comment(
          conn,
          slug,
          Map.put(base_params(post, "hijack"), "parent_uuid", foreign_parent.uuid)
        )

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "no longer available"
      assert PublishingComments.for_post_page(post.uuid).count == 0
    end

    test "a garbage parent_uuid posts as a plain top-level comment", %{
      conn: conn,
      slug: slug,
      post: post
    } do
      # Non-uuid parents are dropped up front (same treatment as a
      # malformed note_id) — the comment still lands, unthreaded, and the
      # junk never reaches the redirect anchor.
      conn =
        post_comment(conn, slug, Map.put(base_params(post, "hi"), "parent_uuid", "not-a-uuid"))

      refute redirected_to(conn) =~ "not-a-uuid"

      page = PublishingComments.for_post_page(post.uuid)
      assert [%{content: "hi", parent_uuid: nil}] = page.thread
    end
  end

  describe "note-anchored comments (panel style)" do
    setup %{slug: slug, user: user} do
      {:ok, _} =
        Groups.update_group(slug, %{"comments_enabled" => "true", "notes_style" => "panel"})

      :ok = login(user)
      :ok
    end

    test "a note comment lands in its panel, not the main thread", %{
      conn: conn,
      slug: slug,
      post: post,
      user: user
    } do
      alias PhoenixKit.Modules.Publishing

      {:ok, read} = Publishing.read_post_by_uuid(post.uuid, "en", 1)

      {:ok, _} =
        Posts.update_post(
          slug,
          read,
          %{"content" => "Uses <Note note=\"The note body.\">a term</Note> here."},
          %{}
        )

      note_id = Renderer.note_dom_id("The note body.")

      conn =
        post_comment(
          conn,
          slug,
          Map.put(base_params(post, "About that note"), "note_id", note_id)
        )

      # Redirect reopens the panel (:target).
      assert redirected_to(conn) =~ "#pk-note-panel-#{note_id}"

      page = PublishingComments.for_post_page(post.uuid)
      assert page.count == 0
      assert [%{content: "About that note"}] = page.note_comments[note_id]

      html = build_conn() |> get("/#{slug}/discussed") |> html_response(200)
      # Body ref targets the panel; the panel carries the note text + comment.
      assert html =~ "#pk-note-panel-#{note_id}"
      assert html =~ "The note body."
      assert html =~ "About that note"
      assert html =~ "1 comment on this note"
      # Main thread header still counts zero.
      assert html =~ "0 comments"

      # A reply to a note comment inherits the note anchor (threads never
      # straddle the panel and the main list).
      [note_comment] = page.note_comments[note_id]

      {:ok, reply} =
        PublishingComments.create(post.uuid, user.uuid, "Reply in panel",
          parent_uuid: note_comment.uuid
        )

      assert reply.metadata["note_id"] == note_id
    end

    test "note-panel threads nest replies and render Reply controls in the panel", %{
      conn: conn,
      slug: slug,
      post: post,
      user: user
    } do
      alias PhoenixKit.Modules.Publishing

      {:ok, read} = Publishing.read_post_by_uuid(post.uuid, "en", 1)

      {:ok, _} =
        Posts.update_post(
          slug,
          read,
          %{"content" => "Uses <Note note=\"Threaded note.\">a term</Note> here."},
          %{}
        )

      note_id = Renderer.note_dom_id("Threaded note.")

      {:ok, root} =
        PublishingComments.create(post.uuid, user.uuid, "Panel root", note_id: note_id)

      conn =
        post_comment(
          conn,
          slug,
          Map.put(base_params(post, "Panel reply"), "parent_uuid", root.uuid)
        )

      # The reply inherited the note anchor, so the redirect reopens the panel.
      assert redirected_to(conn) =~ "#pk-note-panel-#{note_id}"

      page = PublishingComments.for_post_page(post.uuid)

      assert [%{content: "Panel root", children: [%{content: "Panel reply"}]}] =
               page.note_comments[note_id]

      assert PublishingComments.tree_size(page.note_comments[note_id]) == 2

      html = build_conn() |> get("/#{slug}/discussed") |> html_response(200)
      assert html =~ "2 comments on this note"
      assert html =~ "Panel reply"
    end

    test "a malformed note_id posts as a plain thread comment", %{
      conn: conn,
      slug: slug,
      post: post
    } do
      conn =
        post_comment(
          conn,
          slug,
          Map.put(base_params(post, "hello"), "note_id", "<script>alert(1)</script>")
        )

      assert redirected_to(conn) =~ "#comments"
      page = PublishingComments.for_post_page(post.uuid)
      assert page.count == 1
      assert page.note_comments == %{}
    end
  end

  describe "closing a note panel" do
    setup %{slug: slug} do
      {:ok, _} =
        Groups.update_group(slug, %{"comments_enabled" => "true", "notes_style" => "panel"})

      :ok
    end

    test "closing targets a fixed anchor, not the reference in the prose", %{
      conn: conn,
      slug: slug,
      post: post
    } do
      alias PhoenixKit.Modules.Publishing
      alias PhoenixKit.Modules.Publishing.Posts

      {:ok, read} = Publishing.read_post_by_uuid(post.uuid, "en", 1)

      {:ok, _} =
        Posts.update_post(
          slug,
          read,
          %{"content" => ~s(Body with <Note note="A note.">a phrase</Note> in it.)},
          %{}
        )

      html = conn |> get("/#{slug}/#{post.slug}") |> html_response(200)

      # Opening costs nothing — the panel is fixed, so nothing scrolls. The
      # close link used to point back at the reference marker in the text,
      # which the browser then scrolled to the top of the viewport: a 440px
      # jump away from the sentence the reader was already looking at.
      assert html =~ ~s(id="pk-note-dismiss")
      assert html =~ ~s(href="#pk-note-dismiss")

      refute html =~ ~s(class="pk-note-panel-backdrop" aria-label) &&
               html =~ ~s(href="#pk-note-ref-1" class="pk-note-panel-backdrop")

      # The anchor has to be fixed and in view, or closing scrolls to reach it.
      assert html =~ ".pk-note-dismiss{position:fixed"
    end
  end

  describe "moderation" do
    test "a held comment says so instead of claiming it posted", %{
      conn: conn,
      slug: slug,
      post: post,
      user: user
    } do
      {:ok, _} = Groups.update_group(slug, %{"comments_enabled" => "true"})
      # The comments module's own switch: new rows are created "pending".
      {:ok, _} = Settings.update_boolean_setting("comments_moderation", true)
      on_exit(fn -> Settings.update_boolean_setting("comments_moderation", false) end)
      :ok = login(user)

      conn = post_comment(conn, slug, base_params(post, "Held for review"))

      # The thread only lists published rows, so "Comment posted." followed by
      # nothing appearing reads as the site having eaten it.
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "awaiting review"
      refute Phoenix.Flash.get(conn.assigns.flash, :info) =~ "posted"
      assert PublishingComments.for_post_page(post.uuid).count == 0

      html = build_conn() |> get("/#{slug}/discussed") |> html_response(200)
      refute html =~ "Held for review"
    end
  end

  describe "fetch-enhanced submissions (x-pk-comment-fetch)" do
    setup %{slug: slug, user: user} do
      {:ok, _} = Groups.update_group(slug, %{"comments_enabled" => "true"})
      :ok = login(user)
      :ok
    end

    defp post_fetch(conn, slug, params) do
      conn
      |> put_req_header("x-pk-comment-fetch", "1")
      |> post("/#{slug}/discussed", params)
    end

    test "success returns 200 JSON instead of a redirect", %{
      conn: conn,
      slug: slug,
      post: post
    } do
      conn = post_fetch(conn, slug, base_params(post, "Over fetch"))

      assert json_response(conn, 200) == %{"ok" => true, "message" => "Comment posted."}
      assert [%{content: "Over fetch"}] = PublishingComments.for_post_page(post.uuid).thread
    end

    test "errors return 422 JSON with the message", %{conn: conn, slug: slug, post: post} do
      conn = post_fetch(conn, slug, %{base_params(post, "late") | "ft" => "garbage"})

      assert %{"ok" => false, "message" => message} = json_response(conn, 422)
      assert message =~ "expired"
      assert PublishingComments.for_post_page(post.uuid).count == 0
    end

    test "the honeypot still pretends success over fetch", %{
      conn: conn,
      slug: slug,
      post: post
    } do
      params = base_params(post, "spam") |> Map.put("website", "https://spam.example")
      conn = post_fetch(conn, slug, params)

      assert %{"ok" => true} = json_response(conn, 200)
      assert PublishingComments.for_post_page(post.uuid).count == 0
    end

    test "the enhancement script and form markers render", %{conn: conn, slug: slug} do
      html = build_conn() |> get("/#{slug}/discussed") |> html_response(200)
      assert html =~ "data-pk-comment-form"
      assert html =~ "__pkCommentFetch"
    end
  end
end
