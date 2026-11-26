defmodule PhoenixKit.Modules.Publishing.Web.Controller.AccessControlTest do
  @moduledoc """
  Per-post access control through the public controller: every rule kind
  against every viewer state, as a request — the password form and its POST
  (wrong / right / rate-limited), the access cookie (valid / tampered /
  rotated), secret links (redeem / wrong / revoked / expired), sign-in
  redirects, the 404-or-403 choice, the protected response headers, the
  editor bypass and "preview as anonymous", versioned URLs and comments.
  """

  use PhoenixKitPublishing.ConnCase, async: false

  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.Comments, as: PublishingComments
  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.PostAccess
  alias PhoenixKit.Modules.Publishing.PostAccess.Grants
  alias PhoenixKit.Modules.Publishing.Posts
  alias PhoenixKit.Modules.Publishing.Versions
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Roles
  alias PhoenixKitPublishing.LiveCase
  alias PhoenixKitPublishing.Test.Repo, as: TestRepo

  @title "Weekly report for ACME"

  setup do
    {:ok, _} = Settings.update_boolean_setting("publishing_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("publishing_public_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("languages_enabled", false)
    {:ok, _} = Settings.update_setting("content_language", "en")
    {:ok, _} = Settings.update_setting("publishing_access_forbidden_status", "404")

    {:ok, group} = Groups.add_group("acl-#{System.unique_integer([:positive])}", mode: "slug")
    slug = group["slug"]

    {:ok, post} =
      Posts.create_post(slug, %{title: @title, slug: "weekly", content: "Revenue up 12%."})

    :ok = Versions.publish_version(slug, post.uuid, 1)

    %{slug: slug, group: group, post: post, owner: {:post, post.uuid}, path: "/#{slug}/weekly"}
  end

  defp missing_answer(conn, slug) do
    conn = get(conn, "/#{slug}/no-such-post-at-all")
    {conn.status, redirected_to(conn)}
  end

  defp protected_headers?(conn) do
    get_resp_header(conn, "cache-control") == ["private, no-store"] and
      get_resp_header(conn, "x-robots-tag") == ["noindex, nofollow"] and
      get_resp_header(conn, "referrer-policy") == ["no-referrer"]
  end

  defp user_scope(roles \\ ["User"]) do
    LiveCase.fake_scope(
      user_uuid: "019cce93-0000-7000-8000-0000000000cc",
      roles: roles,
      permissions: []
    )
  end

  test "a public post carries no access headers", %{conn: conn, path: path} do
    conn = get(conn, path)
    assert html_response(conn, 200) =~ @title
    assert get_resp_header(conn, "x-robots-tag") == []
    assert get_resp_header(conn, "referrer-policy") == []
    refute conn.resp_body =~ "noindex"
  end

  describe "password" do
    setup %{owner: owner} do
      {:ok, rule} = PostAccess.set_password(owner, "open sesame")
      %{rule: rule}
    end

    test "the form is generic: no title, body or meta of the post", %{conn: conn, path: path} do
      conn = get(conn, path)
      body = response(conn, 401)

      assert body =~ ~s(id="pk-access-password")
      assert body =~ ~s(name="pk_access" value="unlock")
      refute body =~ @title
      refute body =~ "Revenue"
      refute body =~ "og:title"
      assert body =~ ~s(<meta name="robots" content="noindex, nofollow")
      assert protected_headers?(conn)
    end

    test "a wrong password re-shows the form, the right one opens the post", %{
      conn: conn,
      path: path,
      post: post
    } do
      wrong =
        post(conn, path, %{"pk_access" => "unlock", "post_uuid" => post.uuid, "password" => "no"})

      assert response(wrong, 401) =~ "That password didn"
      refute wrong.resp_body =~ @title

      right =
        post(conn, path, %{
          "pk_access" => "unlock",
          "post_uuid" => post.uuid,
          "password" => "open sesame"
        })

      assert redirected_to(right) == path
      assert right.resp_cookies[Grants.cookie_name()]

      page = right |> recycle() |> get(path)
      body = html_response(page, 200)
      assert body =~ @title
      assert body =~ ~s(<meta name="robots" content="noindex, nofollow")
      assert protected_headers?(page)
    end

    test "a tampered cookie is no grant", %{conn: conn, path: path} do
      conn =
        conn
        |> put_req_cookie(Grants.cookie_name(), "SFMyNTY.forged.value")
        |> get(path)

      assert response(conn, 401) =~ "pk-access-password"
    end

    test "rotating the password locks out earlier readers", %{
      conn: conn,
      path: path,
      post: post,
      owner: owner
    } do
      unlocked =
        post(conn, path, %{
          "pk_access" => "unlock",
          "post_uuid" => post.uuid,
          "password" => "open sesame"
        })

      {:ok, _} = PostAccess.set_password(owner, "brand new one")

      assert unlocked |> recycle() |> get(path) |> response(401) =~ "pk-access-password"
    end

    test "attempts are rate-limited per address and post", %{conn: conn, path: path, post: post} do
      conn = %{conn | remote_ip: {10, 9, System.unique_integer([:positive]) |> rem(250), 7}}

      for _ <- 1..5 do
        post(conn, path, %{"pk_access" => "unlock", "post_uuid" => post.uuid, "password" => "x"})
      end

      limited =
        post(conn, path, %{
          "pk_access" => "unlock",
          "post_uuid" => post.uuid,
          "password" => "open sesame"
        })

      assert response(limited, 429) =~ "Too many attempts"
      refute limited.resp_cookies[Grants.cookie_name()]
    end

    test "an unlock for a post of another group is a 404", %{conn: conn, post: post} do
      {:ok, other} = Groups.add_group("other-#{System.unique_integer([:positive])}", mode: "slug")

      conn =
        post(conn, "/#{other["slug"]}/weekly", %{
          "pk_access" => "unlock",
          "post_uuid" => post.uuid,
          "password" => "open sesame"
        })

      assert conn.status == 404
    end
  end

  describe "secret links" do
    setup %{owner: owner} do
      {:ok, rule, key} = PostAccess.create_link(owner, %{"note" => "ACME"})
      %{rule: rule, key: key}
    end

    test "without the key the post answers exactly like a missing one", %{
      conn: conn,
      path: path,
      slug: slug
    } do
      denied = get(conn, path)
      assert {denied.status, redirected_to(denied)} == missing_answer(conn, slug)
      assert get_resp_header(denied, "x-robots-tag") == []
    end

    test "the key is redeemed into the cookie and dropped from the URL", %{
      conn: conn,
      path: path,
      key: key
    } do
      redeemed = get(conn, path <> "?key=" <> key)

      assert redirected_to(redeemed) == path
      assert redeemed.resp_cookies[Grants.cookie_name()]
      assert get_resp_header(redeemed, "referrer-policy") == ["no-referrer"]

      page = redeemed |> recycle() |> get(path)
      assert html_response(page, 200) =~ @title
      assert protected_headers?(page)
    end

    test "other query parameters survive the redirect", %{conn: conn, path: path, key: key} do
      redeemed = get(conn, path <> "?utm=x&key=" <> key)
      assert redirected_to(redeemed) == path <> "?utm=x"
    end

    test "a wrong key is a missing post", %{conn: conn, path: path, slug: slug} do
      denied = get(conn, path <> "?key=" <> String.duplicate("Z", 43))
      assert {denied.status, redirected_to(denied)} == missing_answer(conn, slug)
    end

    test "revoking closes the post for readers who already redeemed", %{
      conn: conn,
      path: path,
      key: key,
      rule: rule,
      slug: slug
    } do
      redeemed = get(conn, path <> "?key=" <> key)
      {:ok, _} = PostAccess.revoke_link(rule.uuid)

      after_revoke = redeemed |> recycle() |> get(path)
      assert {after_revoke.status, redirected_to(after_revoke)} == missing_answer(conn, slug)
    end
  end

  describe "sign-in rules" do
    setup %{owner: owner} do
      {:ok, role} = Roles.create_role(%{name: "ACME #{System.unique_integer([:positive])}"})
      {:ok, _} = PostAccess.add_rule(owner, %{"kind" => "role", "role_uuids" => [role.uuid]})
      %{role: role}
    end

    test "anonymous readers go to the sign-in page and come back", %{conn: conn, path: path} do
      conn = get(conn, path)
      location = redirected_to(conn)

      assert location =~ "/users/log-in"
      assert URI.decode_query(URI.parse(location).query)["return_to"] == path
      assert protected_headers?(conn)
    end

    test "the right role opens the post", %{conn: conn, path: path, role: role} do
      with_scope(user_scope(["User", role.name]))
      assert get(conn, path) |> html_response(200) =~ @title
    end

    test "a wrong role answers like a missing post by default", %{
      conn: conn,
      path: path,
      slug: slug
    } do
      with_scope(user_scope())
      denied = get(conn, path)
      assert {denied.status, redirected_to(denied)} == missing_answer(conn, slug)
    end

    test "or with a 403 when the site says so", %{conn: conn, path: path} do
      {:ok, _} = Settings.update_setting("publishing_access_forbidden_status", "403")
      with_scope(user_scope())
      conn = get(conn, path)

      body = response(conn, 403)
      assert body =~ "pk-access-forbidden"
      refute body =~ @title
      assert protected_headers?(conn)
    end

    test "an editor always passes, and can preview as a stranger", %{conn: conn, path: path} do
      with_scope(LiveCase.fake_scope())
      assert get(conn, path) |> html_response(200) =~ @title

      preview = get(conn, path <> "?pk_preview=anonymous")
      assert redirected_to(preview) =~ "/users/log-in"
    end

    test "a versioned URL is gated too", %{conn: conn, path: path, post: post, slug: slug} do
      {:ok, read} = Publishing.read_post_by_uuid(post.uuid, "en", 1)
      {:ok, _} = Posts.update_post(slug, read, %{"allow_version_access" => "true"}, %{})

      conn = get(conn, path <> "/v/1")
      assert redirected_to(conn) =~ "/users/log-in"
    end
  end

  describe "comments" do
    setup %{slug: slug, owner: owner} do
      {:ok, _} = Settings.update_boolean_setting("comments_enabled", true)
      {:ok, _} = Groups.update_group(slug, %{"comments_enabled" => "true"})
      {:ok, _} = PostAccess.add_rule(owner, %{"kind" => "signed_in"})

      user =
        TestRepo.insert!(%PhoenixKit.Users.Auth.User{
          email: "reader-#{System.unique_integer([:positive])}@example.com",
          hashed_password: "x"
        })

      %{user: user}
    end

    defp comment_params(post) do
      token =
        Phoenix.Token.sign(
          PhoenixKitPublishing.Test.Endpoint,
          "pk_pub_comment",
          System.system_time(:second) - 10
        )

      %{"post_uuid" => post.uuid, "content" => "Thanks!", "ft" => token, "website" => ""}
    end

    test "a reader who may open the post can comment", %{
      conn: conn,
      path: path,
      post: post,
      user: user
    } do
      with_scope(%PhoenixKit.Users.Auth.Scope{
        user: user,
        authenticated?: true,
        cached_roles: ["User"]
      })

      conn = post(conn, path, comment_params(post))

      assert redirected_to(conn) =~ path
      assert [_] = PublishingComments.list(post.uuid)
    end
  end
end
