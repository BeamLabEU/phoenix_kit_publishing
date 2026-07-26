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
  alias PhoenixKit.Modules.Publishing.Versions
  alias PhoenixKit.Settings

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
      PhoenixKitPublishing.Test.Repo.insert!(%PhoenixKit.Users.Auth.User{
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
end
