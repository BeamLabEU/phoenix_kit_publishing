defmodule PhoenixKit.Modules.Publishing.PostAccessTest do
  @moduledoc """
  The access resolver (`PostAccess.authorize_view/2`): every rule kind
  against every viewer state, the match modes, expiry and revocation,
  password rotation, group defaults, the summary and the query filter.
  """

  use PhoenixKitPublishing.DataCase, async: false

  alias PhoenixKit.Modules.Publishing.DBStorage
  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.PostAccess
  alias PhoenixKit.Modules.Publishing.PostAccess.Viewer
  alias PhoenixKit.Modules.Publishing.Posts
  alias PhoenixKit.Modules.Publishing.PublishingAccessRule
  alias PhoenixKit.Modules.Publishing.PublishingPost
  alias PhoenixKit.Modules.Publishing.Versions
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Roles

  setup do
    {:ok, _} = Settings.update_boolean_setting("publishing_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("languages_enabled", false)
    {:ok, _} = Settings.update_setting("content_language", "en")

    {:ok, group} = Groups.add_group("acl-#{System.unique_integer([:positive])}", mode: "slug")

    {:ok, post} =
      Posts.create_post(group["slug"], %{title: "Report", slug: "report", content: "Body"})

    :ok = Versions.publish_version(group["slug"], post.uuid, 1)

    {:ok, role} = Roles.create_role(%{name: "Client ACME #{System.unique_integer([:positive])}"})

    %{group: group, post: post, owner: {:post, post.uuid}, role: role}
  end

  # ── viewers ────────────────────────────────────────────────────────────

  @user_uuid "019cce93-0000-7000-8000-0000000000aa"
  @other_uuid "019cce93-0000-7000-8000-0000000000bb"

  defp anon, do: Viewer.anonymous()

  defp signed_in(roles \\ ["User"], uuid \\ @user_uuid),
    do: %Viewer{user_uuid: uuid, anonymous?: false, role_names: roles}

  defp editor, do: %Viewer{user_uuid: @other_uuid, anonymous?: false, bypass?: true}

  defp with_grant(viewer, rule, rev \\ nil, exp \\ nil) do
    grant = %{
      "r" => rev || PostAccess.revision(rule),
      "e" => exp || System.system_time(:second) + 3600
    }

    %{viewer | grants: Map.put(viewer.grants, rule.uuid, grant)}
  end

  defp with_key(viewer, key), do: %{viewer | key: key}

  defp access(owner), do: owner |> PostAccess.list_rules() |> PostAccess.to_access()

  # ── public ─────────────────────────────────────────────────────────────

  test "a post without rules is public for everyone", %{post: post} do
    assert PostAccess.access_for_post(post.uuid) == nil
    assert PostAccess.authorize_view(nil, anon()) == :ok
    assert PostAccess.authorize_view(nil, signed_in()) == :ok
    refute PostAccess.protected?(post.uuid)
  end

  test "a settings row alone does not protect a post", %{owner: owner, post: post} do
    {:ok, _} = PostAccess.put_settings(owner, %{"match" => "all"})
    refute PostAccess.protected?(post.uuid)
  end

  # ── the matrix ─────────────────────────────────────────────────────────

  describe "signed_in rule" do
    setup %{owner: owner} do
      {:ok, _} = PostAccess.add_rule(owner, %{"kind" => "signed_in"})
      :ok
    end

    test "anonymous → login; any account → ok; editor → ok", %{owner: owner} do
      a = access(owner)
      assert PostAccess.authorize_view(a, anon()) == {:error, :login}
      assert PostAccess.authorize_view(a, signed_in()) == :ok
      assert PostAccess.authorize_view(a, editor()) == :ok
    end
  end

  describe "role rule" do
    setup %{owner: owner, role: role} do
      {:ok, _} = PostAccess.add_rule(owner, %{"kind" => "role", "role_uuids" => [role.uuid]})
      :ok
    end

    test "anonymous → login, wrong role → forbidden, right role → ok, editor → ok",
         %{owner: owner, role: role} do
      a = access(owner)
      assert PostAccess.authorize_view(a, anon()) == {:error, :login}
      assert PostAccess.authorize_view(a, signed_in(["User"])) == {:error, :forbidden}
      assert PostAccess.authorize_view(a, signed_in(["User", role.name])) == :ok
      assert PostAccess.authorize_view(a, editor()) == :ok
    end

    test "a role rule with no known role refuses", %{group: group} do
      {:ok, other} = Posts.create_post(group["slug"], %{title: "X", slug: "x", content: "x"})

      assert {:error, :empty_rule} =
               PostAccess.add_rule({:post, other.uuid}, %{
                 "kind" => "role",
                 "role_uuids" => ["nope"]
               })
    end
  end

  describe "user rule" do
    setup %{owner: owner} do
      {:ok, _} = PostAccess.add_rule(owner, %{"kind" => "user", "user_uuids" => [@user_uuid]})
      :ok
    end

    test "only the named account", %{owner: owner} do
      a = access(owner)
      assert PostAccess.authorize_view(a, anon()) == {:error, :login}

      assert PostAccess.authorize_view(a, signed_in(["User"], @other_uuid)) ==
               {:error, :forbidden}

      assert PostAccess.authorize_view(a, signed_in(["User"], @user_uuid)) == :ok
    end
  end

  describe "password rule" do
    setup %{owner: owner} do
      {:ok, rule} = PostAccess.set_password(owner, "open sesame")
      %{rule: rule}
    end

    test "no grant → password form, for anonymous and signed-in alike", %{owner: owner} do
      a = access(owner)
      assert PostAccess.authorize_view(a, anon()) == {:error, :password}
      assert PostAccess.authorize_view(a, signed_in()) == {:error, :password}
      assert PostAccess.authorize_view(a, editor()) == :ok
    end

    test "the right password grants, a wrong one does not", %{owner: owner, rule: rule} do
      a = access(owner)
      assert {:ok, %{uuid: uuid}} = PostAccess.check_password(a, "open sesame")
      assert uuid == rule.uuid
      assert PostAccess.check_password(a, "wrong") == :error
      assert PostAccess.check_password(a, "") == :error
    end

    test "a valid grant opens it; an expired grant does not", %{owner: owner, rule: rule} do
      a = access(owner)
      assert PostAccess.authorize_view(a, with_grant(anon(), rule)) == :ok

      expired = with_grant(anon(), rule, nil, System.system_time(:second) - 1)
      assert PostAccess.authorize_view(a, expired) == {:error, :password}
    end

    test "rotating the password revokes every earlier grant", %{owner: owner, rule: rule} do
      viewer = with_grant(anon(), rule)
      {:ok, rotated} = PostAccess.set_password(owner, "new secret")

      assert rotated.uuid == rule.uuid
      assert PostAccess.revision(rotated) == PostAccess.revision(rule) + 1
      assert PostAccess.authorize_view(access(owner), viewer) == {:error, :password}
      assert PostAccess.check_password(access(owner), "open sesame") == :error
      assert {:ok, _} = PostAccess.check_password(access(owner), "new secret")
    end

    test "a rotation without an end date keeps the rule's end date", %{owner: owner} do
      until = DateTime.add(DateTime.utc_now(), 7 * 86_400, :second) |> DateTime.truncate(:second)
      {:ok, dated} = PostAccess.set_password(owner, "dated one", %{"expires_at" => until})
      assert dated.expires_at == until

      {:ok, rotated} = PostAccess.set_password(owner, "rotated one", %{"expires_at" => ""})
      assert rotated.expires_at == until
    end

    test "a rotation leaves one password: a second row stops working too", %{
      owner: owner,
      post: post
    } do
      # Two first saves racing could each insert a password row.
      PhoenixKit.RepoHelper.repo().insert!(%PublishingAccessRule{
        post_uuid: post.uuid,
        kind: "password",
        config: %{"hash" => Bcrypt.hash_pwd_salt("second row"), "rev" => 1}
      })

      assert {:ok, _} = PostAccess.check_password(access(owner), "second row")
      {:ok, _} = PostAccess.set_password(owner, "only this one")

      assert PostAccess.check_password(access(owner), "second row") == :error
      assert PostAccess.check_password(access(owner), "open sesame") == :error
      assert {:ok, _} = PostAccess.check_password(access(owner), "only this one")
    end

    test "the hash is Bcrypt and the password itself is nowhere", %{rule: rule} do
      assert "$2b$" <> _ = rule.config["hash"]
      refute inspect(rule) =~ "open sesame"
    end

    test "too short a password is refused", %{group: group} do
      {:ok, other} = Posts.create_post(group["slug"], %{title: "Y", slug: "y", content: "y"})
      assert {:error, :password_too_short} = PostAccess.set_password({:post, other.uuid}, "abc")
    end
  end

  describe "secret links" do
    setup %{owner: owner} do
      {:ok, rule, key} = PostAccess.create_link(owner, %{"note" => "ACME Ltd"})
      %{rule: rule, key: key}
    end

    test "only the digest is stored", %{rule: rule, key: key} do
      assert byte_size(key) >= 43
      assert rule.config["digest"] == PostAccess.digest(key)
      refute inspect(rule) =~ key
      assert rule.note == "ACME Ltd"
    end

    test "without the link the post does not exist; the key redeems", %{
      owner: owner,
      rule: rule,
      key: key
    } do
      a = access(owner)
      assert PostAccess.authorize_view(a, anon()) == {:error, :not_found}
      assert PostAccess.authorize_view(a, signed_in()) == {:error, :not_found}
      assert {:redeem, %{uuid: uuid}} = PostAccess.authorize_view(a, with_key(anon(), key))
      assert uuid == rule.uuid
      assert PostAccess.authorize_view(a, with_grant(anon(), rule)) == :ok
    end

    test "a wrong key does not redeem", %{owner: owner} do
      wrong = String.duplicate("A", 43)

      assert PostAccess.authorize_view(access(owner), with_key(anon(), wrong)) ==
               {:error, :not_found}
    end

    test "revoking ends the link and every grant made from it", %{
      owner: owner,
      rule: rule,
      key: key
    } do
      {:ok, _} = PostAccess.revoke_link(rule.uuid)
      a = access(owner)

      assert PostAccess.authorize_view(a, with_grant(anon(), rule)) == {:error, :not_found}
      assert PostAccess.authorize_view(a, with_key(anon(), key)) == {:error, :not_found}
      # Revoking a link never makes the post public.
      assert PostAccess.protected?(rule.post_uuid)
    end

    test "an expired link stops working", %{group: group} do
      {:ok, post} = Posts.create_post(group["slug"], %{title: "E", slug: "e", content: "e"})
      past = DateTime.add(DateTime.utc_now(), -60, :second)
      {:ok, rule, key} = PostAccess.create_link({:post, post.uuid}, %{"expires_at" => past})
      a = access({:post, post.uuid})

      assert PostAccess.authorize_view(a, with_key(anon(), key)) == {:error, :not_found}
      assert PostAccess.authorize_view(a, with_grant(anon(), rule)) == {:error, :not_found}
    end
  end

  describe "match modes" do
    setup %{owner: owner, role: role} do
      {:ok, _} = PostAccess.add_rule(owner, %{"kind" => "role", "role_uuids" => [role.uuid]})
      {:ok, pw} = PostAccess.set_password(owner, "pass word")
      %{pw: pw}
    end

    test "any: role OR password", %{owner: owner, role: role, pw: pw} do
      a = access(owner)
      assert PostAccess.authorize_view(a, signed_in([role.name])) == :ok
      assert PostAccess.authorize_view(a, with_grant(anon(), pw)) == :ok
      assert PostAccess.authorize_view(a, anon()) == {:error, :password}
    end

    test "all: role AND password", %{owner: owner, role: role, pw: pw} do
      {:ok, _} = PostAccess.put_settings(owner, %{"match" => "all"})
      a = access(owner)
      assert a.match == "all"

      assert PostAccess.authorize_view(a, signed_in([role.name])) == {:error, :password}
      assert PostAccess.authorize_view(a, with_grant(anon(), pw)) == {:error, :login}

      assert PostAccess.authorize_view(a, with_grant(signed_in(["User"]), pw)) ==
               {:error, :forbidden}

      assert PostAccess.authorize_view(a, with_grant(signed_in([role.name]), pw)) == :ok
    end

    test "all: an expired kind closes the post instead of dropping out", %{
      owner: owner,
      role: role
    } do
      {:ok, _} = PostAccess.put_settings(owner, %{"match" => "all"})
      past = DateTime.add(DateTime.utc_now(), -60, :second)
      {:ok, pw} = PostAccess.set_password(owner, "pass word", %{"expires_at" => past})
      a = access(owner)

      # "role AND password until <past>" must not become "role".
      assert PostAccess.authorize_view(a, signed_in([role.name])) == {:error, :not_found}

      assert PostAccess.authorize_view(a, with_grant(signed_in([role.name]), pw)) ==
               {:error, :not_found}

      assert PostAccess.authorize_view(a, editor()) == :ok
    end

    test "any: an expired kind only narrows", %{owner: owner, role: role} do
      past = DateTime.add(DateTime.utc_now(), -60, :second)
      {:ok, _} = PostAccess.set_password(owner, "pass word", %{"expires_at" => past})
      a = access(owner)

      assert PostAccess.authorize_view(a, signed_in([role.name])) == :ok
      assert PostAccess.authorize_view(a, anon()) == {:error, :login}
    end
  end

  test "an expired rule grants nothing and the post stays closed", %{owner: owner} do
    past = DateTime.add(DateTime.utc_now(), -60, :second)
    {:ok, _} = PostAccess.add_rule(owner, %{"kind" => "signed_in", "expires_at" => past})
    a = access(owner)

    assert PostAccess.authorize_view(a, signed_in()) == {:error, :not_found}
    assert PostAccess.authorize_view(a, editor()) == :ok
  end

  test "authorize_view/3 takes a scope and grants", %{owner: owner} do
    {:ok, _} = PostAccess.add_rule(owner, %{"kind" => "signed_in"})
    scope = PhoenixKitPublishing.LiveCase.fake_scope(permissions: [], roles: ["User"])

    assert PostAccess.authorize_view(access(owner), scope, %{}) == :ok
    assert PostAccess.authorize_view(access(owner), nil, %{}) == {:error, :login}
  end

  test "a publishing permission holder always passes", %{owner: owner} do
    {:ok, _, _} = PostAccess.create_link(owner)
    scope = PhoenixKitPublishing.LiveCase.fake_scope()
    assert PostAccess.authorize_view(access(owner), scope, %{}) == :ok
  end

  # ── writes ─────────────────────────────────────────────────────────────

  test "clear/1 makes the post public again, links included", %{owner: owner, post: post} do
    {:ok, _} = PostAccess.add_rule(owner, %{"kind" => "signed_in"})
    {:ok, _, _} = PostAccess.create_link(owner)
    :ok = PostAccess.clear(owner)
    refute PostAccess.protected?(post.uuid)
    assert PostAccess.list_rules(owner) == []
  end

  test "a rule needs exactly one owner" do
    refute PublishingAccessRule.changeset(%PublishingAccessRule{}, %{kind: "signed_in"}).valid?
  end

  test "every change is logged without secrets", %{owner: owner, post: post} do
    {:ok, _} = PostAccess.set_password(owner, "logged secret")

    assert_activity_logged("publishing.access.changed",
      resource_uuid: post.uuid,
      metadata_has: %{"change" => "password_added"}
    )

    refute inspect(list_activities()) =~ "logged secret"
  end

  describe "group defaults" do
    test "a copy that fails part-way leaves the post's own rules in place", %{
      group: group,
      post: post,
      owner: owner
    } do
      {:ok, _} = PostAccess.set_password(owner, "post's own")

      # A default row the changeset refuses (written around it): its copy
      # fails after the post's own rules were deleted.
      PhoenixKit.RepoHelper.repo().insert!(%PublishingAccessRule{
        group_uuid: group["uuid"],
        kind: "bogus",
        config: %{}
      })

      assert_raise Ecto.InvalidChangesetError, fn ->
        PostAccess.apply_group_defaults(group["uuid"])
      end

      assert PostAccess.protected?(post.uuid)
      assert {:ok, _} = PostAccess.check_password(access(owner), "post's own")
    end

    test "a new post copies the group's rules (never links)", %{group: group, role: role} do
      gowner = {:group, group["uuid"]}
      {:ok, _} = PostAccess.add_rule(gowner, %{"kind" => "role", "role_uuids" => [role.uuid]})
      {:ok, _} = PostAccess.put_settings(gowner, %{"match" => "all", "list_protected" => true})

      {:ok, post} = Posts.create_post(group["slug"], %{title: "New", slug: "new", content: "n"})
      rules = PostAccess.list_rules({:post, post.uuid})

      assert Enum.map(rules, & &1.kind) |> Enum.sort() == ["role", "settings"]
      assert PostAccess.match_of(rules) == "all"
      # The listing flag is the group's, not the post's.
      refute PostAccess.list_protected?(rules)
    end

    test "apply to existing posts, with a preview count", %{group: group, post: post} do
      gowner = {:group, group["uuid"]}
      {:ok, _} = PostAccess.add_rule(gowner, %{"kind" => "signed_in"})
      {:ok, custom} = Posts.create_post(group["slug"], %{title: "C", slug: "c", content: "c"})
      # `custom` got the default at creation; give it its own rule instead.
      :ok = PostAccess.clear({:post, custom.uuid})
      {:ok, _, _} = PostAccess.create_link({:post, custom.uuid})

      assert PostAccess.preview_group_defaults(group["uuid"]) == 2
      assert PostAccess.preview_group_defaults(group["uuid"], keep_custom: true) == 1

      {:ok, 1} = PostAccess.apply_group_defaults(group["uuid"], keep_custom: true)
      assert PostAccess.protected?(post.uuid)
      assert Enum.map(PostAccess.list_rules({:post, custom.uuid}), & &1.kind) == ["token"]

      {:ok, 2} = PostAccess.apply_group_defaults(group["uuid"])
      # Secret links survive a re-apply.
      assert Enum.sort(Enum.map(PostAccess.list_rules({:post, custom.uuid}), & &1.kind)) ==
               ["signed_in", "token"]
    end
  end

  # ── reading helpers ────────────────────────────────────────────────────

  test "visible_query/1 keeps public posts only", %{group: group, post: post, owner: owner} do
    {:ok, open} = Posts.create_post(group["slug"], %{title: "Open", slug: "open", content: "o"})
    {:ok, _} = PostAccess.add_rule(owner, %{"kind" => "signed_in"})

    uuids =
      from(p in PublishingPost, where: p.group_uuid == ^group["uuid"])
      |> PostAccess.visible_query()
      |> Repo.all()
      |> Enum.map(& &1.uuid)

    assert open.uuid in uuids
    refute post.uuid in uuids
  end

  test "the summary reads as a sentence", %{owner: owner, role: role} do
    assert PostAccess.summary([]) =~ "Public"

    {:ok, _} = PostAccess.add_rule(owner, %{"kind" => "role", "role_uuids" => [role.uuid]})
    {:ok, _} = PostAccess.set_password(owner, "pass word", %{"expires_at" => "2030-06-30"})
    summary = PostAccess.summary(PostAccess.list_rules(owner))

    assert summary =~ role.name
    assert summary =~ "password"
    assert summary =~ "2030-06-30"
    assert summary =~ " or "
  end

  test "the listing cache marks protected posts, and only them", %{group: group, owner: owner} do
    {:ok, _open} = Posts.create_post(group["slug"], %{title: "Open", slug: "open", content: "o"})
    {:ok, _} = PostAccess.add_rule(owner, %{"kind" => "signed_in"})

    entries = DBStorage.list_posts_for_listing(group["slug"])
    protected = Enum.filter(entries, &(&1[:access_protected] == true))

    assert [%{slug: "report"}] = protected
    assert Enum.all?(entries -- protected, &(not Map.has_key?(&1, :access_protected)))
  end
end
