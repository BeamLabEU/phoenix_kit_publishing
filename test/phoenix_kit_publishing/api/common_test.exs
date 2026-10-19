defmodule PhoenixKit.Modules.Publishing.API.CommonTest do
  use PhoenixKitPublishing.DataCase, async: false

  import ExUnit.CaptureLog

  alias PhoenixKit.Modules.Publishing.API.{Common, TextScan}
  alias PhoenixKit.Modules.Publishing.{DBStorage, Posts, Versions}
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Roles
  alias PhoenixKitPublishing.Test.{ApiCase, ApiChangesetSchema}
  alias PhoenixKitPublishing.Test.ApiFixtures, as: Fx
  alias PhoenixKitPublishing.Test.Repo, as: TestRepo

  describe "write_opts/3" do
    test "carries actor, auto mode, scope and the API metadata, never :mode" do
      ctx = ApiCase.ctx(%{approved_by_uuid: "00000000-0000-7000-8000-0000000000aa"})
      opts = Common.write_opts(ctx, "publishing.update_post", publish: false)

      assert opts[:actor_uuid] == ApiCase.user_uuid()
      assert opts[:activity_mode] == "auto"
      assert opts[:publish] == false
      refute Keyword.has_key?(opts, :mode)

      assert %{
               "via" => "api",
               "key_prefix" => "abcd1234",
               "request_id" => "req-test",
               "tool" => "publishing.update_post",
               "approved_by_uuid" => "00000000-0000-7000-8000-0000000000aa"
             } = opts[:log_metadata]
    end

    test "extra overrides the defaults" do
      opts = Common.write_opts(ApiCase.ctx(), "t", activity_mode: "manual")
      assert opts[:activity_mode] == "manual"
    end

    test "a scope passed in extra is used as is and costs no lookup; without it the scope is looked up once" do
      me = self()
      handler = "write-opts-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        TestRepo.config()[:telemetry_prefix] ++ [:query],
        fn _event, _measurements, _meta, _config -> send(me, :query) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      opts = Common.write_opts(ApiCase.ctx(), "t", scope: :already_built)
      assert opts[:scope] == :already_built
      refute_received :query

      user = Fx.user!()
      ctx = ApiCase.ctx()
      ctx = %{ctx | actor: %{ctx.actor | user_uuid: user.uuid}}
      assert %Scope{} = Common.write_opts(ctx, "t")[:scope]
      assert_received :query
    end
  end

  describe "scope/1" do
    test "is the full union of the actor's roles, not the narrowed active role; nil for a missing user" do
      # the settings cache is not started in the test environment, so the sandbox rollback
      # undoes this write and nothing leaks into later tests
      capture_log(fn ->
        {:ok, _} = PhoenixKit.Settings.update_boolean_setting("role_switcher_enabled", true)
      end)

      user = Fx.user!()
      {:ok, seller} = Roles.create_role(%{name: "Seller #{System.unique_integer([:positive])}"})
      {:ok, _} = Roles.assign_role(user, "Admin")
      {:ok, _} = Roles.assign_role(user, seller.name)
      ctx = ApiCase.ctx()
      ctx = %{ctx | actor: %{ctx.actor | user_uuid: user.uuid}}

      # the default for the same user is narrowed to one role; the API's scope is not
      narrowed = Scope.for_user(Auth.get_user(user.uuid))
      assert Scope.narrowed?(narrowed)

      scope = Common.scope(ctx)
      refute Scope.narrowed?(scope)
      assert scope.user.uuid == user.uuid
      assert "Admin" in scope.cached_roles and seller.name in scope.cached_roles

      gone = %{ctx | actor: %{ctx.actor | user_uuid: Ecto.UUID.generate()}}
      assert Common.scope(gone) == nil
    end
  end

  describe "fingerprint/1" do
    test "is deterministic, 64 lowercase hex characters, and follows the term" do
      a = Common.fingerprint(%{a: 1, b: [1, 2]})
      assert a == Common.fingerprint(%{b: [1, 2], a: 1})
      assert a =~ ~r/\A[0-9a-f]{64}\z/
      refute a == Common.fingerprint(%{a: 2, b: [1, 2]})
    end

    test "digest/2 keeps ('ab','c') and ('a','bc') apart" do
      refute Common.digest("ab", "c") == Common.digest("a", "bc")
    end
  end

  describe "rows, summary and batch results" do
    test "row_ok and row_error carry the ref, the action and the error body" do
      assert Common.row_ok("r1", "create", "id-1", %{"slug" => "s"}) ==
               %{"ref" => "r1", "action" => "create", "id" => "id-1", "slug" => "s"}

      assert Common.row_error("r2", :slug_taken, "taken", %{"a" => 1}) ==
               %{
                 "ref" => "r2",
                 "action" => "error",
                 "error" => %{
                   "code" => "slug_taken",
                   "message" => "taken",
                   "context" => %{"a" => 1}
                 }
               }
    end

    test "row_from_error uses the reason as the code, else the core code, and never the raw reason" do
      assert %{"error" => %{"code" => "slug_taken", "context" => ctx}} =
               Common.row_from_error("r", :slug_already_exists)

      assert ctx == %{}

      assert %{"error" => %{"code" => "not_found"}} = Common.row_from_error("r", :post_not_found)

      log =
        capture_log(fn ->
          assert %{"error" => %{"code" => "internal_error", "message" => message}} =
                   Common.row_from_error("r", {:secret_tag, "customer text"})

          refute message =~ "secret_tag"
        end)

      refute log =~ "customer text"
    end

    test "row_from_error keeps the field errors of a changeset" do
      changeset = ApiChangesetSchema.changeset(%{"name" => "toolong"})

      assert %{"error" => %{"code" => "validation_failed", "context" => %{"errors" => errors}}} =
               Common.row_from_error("r", changeset)

      assert [%{"path" => "name", "message" => message}] = errors
      assert message =~ "3"
    end

    test "summary counts rows by action and batch_result wraps rows and summary" do
      rows = [
        Common.row_ok("a", "create", "1"),
        Common.row_ok("b", "create", "2"),
        Common.row_error("c", :x, "m")
      ]

      assert Common.summary(rows) == %{"create" => 2, "error" => 1}

      assert {:ok, %{"results" => ^rows, "summary" => %{"create" => 2, "error" => 1}}} =
               Common.batch_result(rows)

      assert Common.summary([]) == %{}
    end

    test "with_warnings leaves the body alone without warnings and adds them otherwise" do
      assert Common.with_warnings(%{"a" => 1}, []) == %{"a" => 1}
      assert Common.with_warnings(%{"a" => 1}, ["w"]) == %{"a" => 1, "warnings" => ["w"]}
    end
  end

  describe "changeset_errors/1" do
    test "interpolates the options of a message, never inspects" do
      errors = Common.changeset_errors(ApiChangesetSchema.changeset(%{"name" => "toolong"}))
      assert [%{path: "name", message: message}] = errors
      assert is_binary(message) and message =~ "3" and not (message =~ "%{")
    end

    test "a placeholder without a matching option stays as written" do
      changeset =
        ApiChangesetSchema.changeset(%{"name" => "ok"})
        |> Ecto.Changeset.add_error(:name, "needs %{count} items and %{other}", other: 7)

      assert [%{path: "name", message: "needs %{count} items and 7"}] =
               Common.changeset_errors(changeset)
    end

    test "flattens nested embed errors into dotted paths with string messages" do
      changeset =
        ApiChangesetSchema.changeset(%{
          "child" => %{"label" => ""},
          "items" => [%{"label" => "ok"}, %{"label" => ""}]
        })

      errors = Common.changeset_errors(changeset)
      assert Enum.all?(errors, &(is_binary(&1.path) and is_binary(&1.message)))
      assert Enum.map(errors, & &1.path) |> Enum.sort() == ["child.label", "items.label"]
    end
  end

  describe "preview/3 and post_state/4" do
    test "the fingerprint covers the given term and ignores the rows; without a term it covers the rows" do
      {:preview, p1, f1} = Common.preview([%{"a" => 1}], %{}, {:term, 1})
      {:preview, _p2, f2} = Common.preview([%{"a" => 2}], %{}, {:term, 1})
      {:preview, _p3, f3} = Common.preview([%{"a" => 1}])
      {:preview, _p4, f4} = Common.preview([%{"a" => 2}])
      assert f1 == f2 and f3 != f4
      assert p1["rows"] == [%{"a" => 1}] and p1["summary"] == %{nil => 1}
    end

    test "post_state changes with a body or a version status and not with updated_at" do
      g = Fx.group!()
      post = Fx.post!(g["slug"], %{title: "S", slug: "s"})
      db = DBStorage.get_post_by_uuid(post[:uuid])
      version = DBStorage.get_version(post[:uuid], 1)
      [content] = DBStorage.list_contents(version.uuid)
      base = Common.post_state(db, nil, [version], [content])

      assert base ==
               Common.post_state(db, nil, [version], [
                 %{content | updated_at: ~U[2030-01-01 00:00:00Z]}
               ])

      refute base == Common.post_state(db, nil, [version], [%{content | content: "other"}])
      refute base == Common.post_state(db, nil, [%{version | status: "archived"}], [content])
    end

    test "post_state follows the group status, the version tuple, the slug and the post columns" do
      g = Fx.group!()
      post = Fx.post!(g["slug"], %{title: "S2", slug: "s2"})
      db = DBStorage.get_post_by_uuid(post[:uuid])
      version = DBStorage.get_version(post[:uuid], 1)
      [content] = DBStorage.list_contents(version.uuid)
      group = %{status: "active"}
      base = Common.post_state(db, group, [version], [content])

      changed = [
        Common.post_state(db, %{status: "trashed"}, [version], [content]),
        Common.post_state(db, nil, [version], [content]),
        Common.post_state(%{db | slug: "other"}, group, [version], [content]),
        Common.post_state(%{db | trashed_at: ~U[2030-01-01 00:00:00Z]}, group, [version], [
          content
        ]),
        Common.post_state(%{db | active_version_uuid: Ecto.UUID.generate()}, group, [version], [
          content
        ]),
        Common.post_state(db, group, [%{version | version_number: 9}], [content]),
        Common.post_state(db, group, [%{version | published_at: ~U[2030-01-01 00:00:00Z]}], [
          content
        ]),
        Common.post_state(db, group, [%{version | data: %{"x" => 1}}], [content]),
        Common.post_state(db, group, [], [content]),
        Common.post_state(db, group, [version], [%{content | language: "de"}]),
        Common.post_state(db, group, [version], [])
      ]

      for state <- changed, do: refute(state == base)
      assert length(Enum.uniq(changed)) == length(changed)
    end

    test "put_log_fields adds names only; reason_text never inspects" do
      opts = Common.put_log_fields([log_metadata: %{"via" => "api"}], ["title"])
      assert opts[:log_metadata] == %{"via" => "api", "fields" => ["title"]}
      assert Common.reason_text(:timeout) == "timeout"
      assert Common.reason_text(%{secret: 1}) == "failed"
    end
  end

  describe "check_revision/4, validate_slug/2 and og_params/2" do
    test "check_revision passes without if_revision and with the current value, refuses a stale one" do
      g = Fx.group!()
      post = Fx.post!(g["slug"], %{title: "R", slug: "r"})
      db = DBStorage.get_post_by_uuid(post[:uuid])
      version = DBStorage.get_version(post[:uuid], 1)
      [content] = DBStorage.list_contents(version.uuid)
      current = Common.post_revision(db, version, content)
      assert :ok = Common.check_revision(%{}, db, version, content)
      assert :ok = Common.check_revision(%{"if_revision" => current}, db, version, content)

      assert {:error, :revision_mismatch, _, %{current_revision: ^current}} =
               Common.check_revision(%{"if_revision" => "stale"}, db, version, content)
    end

    test "check_revision fails closed on an if_revision that is not a string" do
      g = Fx.group!()
      post = Fx.post!(g["slug"], %{title: "R2", slug: "r2"})
      db = DBStorage.get_post_by_uuid(post[:uuid])
      version = DBStorage.get_version(post[:uuid], 1)
      [content] = DBStorage.list_contents(version.uuid)
      current = Common.post_revision(db, version, content)

      for bad <- [123, true, %{}, ["x"]] do
        assert {:error, :revision_mismatch, _, %{current_revision: ^current}} =
                 Common.check_revision(%{"if_revision" => bad}, db, version, content)
      end

      assert :ok = Common.check_revision(%{"if_revision" => nil}, db, version, content)
    end

    test "validate_slug returns the slug or a handler error with the given path" do
      assert {:ok, "fine-slug"} = Common.validate_slug("fine-slug")

      assert {:error, :validation_failed, _, %{errors: [%{path: "slug", reason: "invalid_slug"}]}} =
               Common.validate_slug("Not Valid")

      assert {:error, :validation_failed, _,
              %{errors: [%{path: "name", reason: "reserved_route_word"}]}} =
               Common.validate_slug("admin", "name")
    end

    test "og_params is empty without og keys and sends all three with any, merging the current values" do
      assert Common.og_params(%{"title" => "x"}, nil) == %{}

      current = %PhoenixKit.Modules.Publishing.PublishingContent{
        data: %{"og" => %{"title" => "T", "description" => "D", "image_uuid" => "I"}}
      }

      assert Common.og_params(%{"og_title" => "New"}, current) == %{
               "og_title" => "New",
               "og_description" => "D",
               "og_image_uuid" => "I"
             }

      assert Common.og_params(%{"og_image_id" => nil}, current) == %{
               "og_title" => "T",
               "og_description" => "D",
               "og_image_uuid" => ""
             }
    end
  end

  describe "slug_taken?/2" do
    test "free, live and trashed" do
      g = Fx.group!()
      assert Common.slug_taken?(g["slug"], "hello") == false
      post = Fx.post!(g["slug"], %{title: "Hello", slug: "hello"})
      assert Common.slug_taken?(g["slug"], "hello") == {true, :live}
      {:ok, _} = Posts.trash_post(g["slug"], post[:uuid])
      assert Common.slug_taken?(g["slug"], "hello") == {true, :trashed}
      assert Common.slug_taken?(g["slug"], "other") == false
    end

    test "a trashed post of another group does not take the slug" do
      g1 = Fx.group!()
      g2 = Fx.group!()
      post = Fx.post!(g1["slug"], %{title: "Hello", slug: "hello"})
      {:ok, _} = Posts.trash_post(g1["slug"], post[:uuid])
      assert Common.slug_taken?(g2["slug"], "hello") == false
    end

    test "a database error raises instead of answering free" do
      g = Fx.group!()

      TestRepo.query!(
        "ALTER TABLE phoenix_kit_publishing_posts RENAME TO phoenix_kit_publishing_posts_x"
      )

      assert_raise Postgrex.Error, fn -> Common.slug_taken?(g["slug"], "hello") end
    end
  end

  describe "strict category reads" do
    test "categories!/1 and category_tree!/1 are in tree order with depth; counts are exact" do
      g = Fx.group!()
      parent = Fx.category!(g["slug"], "Parent")
      child = Fx.category!(g["slug"], "Child", %{parent_uuid: parent.uuid})
      assert [{p, 0}, {c, 1}] = Common.category_tree!(g["slug"])
      assert p.uuid == parent.uuid and c.uuid == child.uuid
      assert length(Common.categories!(g["slug"])) == 2
      assert Common.published_post_counts!(g["slug"]) == %{}
    end

    test "published_post_counts!/1 counts the ACTIVE version of live posts only" do
      g = Fx.group!()
      a = Fx.category!(g["slug"], "Cat A")
      b = Fx.category!(g["slug"], "Cat B")
      other = Fx.group!()
      c = Fx.category!(other["slug"], "Cat C")

      # published, filed in A and B (twice in A: counted once)
      one = published_post!(g, "one", [a.uuid, a.uuid, b.uuid])
      # published, filed in A; a newer unpublished version files it in B
      two = published_post!(g, "two", [a.uuid])
      {:ok, _} = Versions.create_new_version(g["slug"], elem(Posts.read_post_by_uuid(two), 1))
      file!(two, 2, [b.uuid])
      # a draft: not counted
      draft = Fx.post!(g["slug"], %{title: "Draft", slug: "draft"})
      file!(draft[:uuid], 1, [a.uuid])
      # published and then trashed: not counted
      gone = published_post!(g, "gone", [a.uuid, b.uuid])
      {:ok, _} = Posts.trash_post(g["slug"], gone)
      # another group: not counted
      published_post!(other, "elsewhere", [c.uuid])

      assert one != two
      assert Common.published_post_counts!(g["slug"]) == %{a.uuid => 2, b.uuid => 1}
      assert Common.published_post_counts!(other["slug"]) == %{c.uuid => 1}
    end

    test "a database error raises instead of answering an empty result" do
      g = Fx.group!()

      TestRepo.query!(
        "ALTER TABLE phoenix_kit_publishing_categories RENAME TO phoenix_kit_publishing_categories_x"
      )

      assert_raise Postgrex.Error, fn -> Common.categories!(g["slug"]) end
      assert_raise Postgrex.Error, fn -> Common.category_tree!(g["slug"]) end
      # rolled back with the sandbox transaction
    end

    test "filed_versions_counts!/2 counts versions of the group that name each category" do
      g = Fx.group!()
      cat = Fx.category!(g["slug"], "Filed")
      post = Fx.post!(g["slug"], %{title: "P", slug: "p"})
      {:ok, p} = Posts.read_post_by_uuid(post[:uuid])

      {:ok, _} =
        Posts.update_post(g["slug"], p, %{"category_uuids" => [cat.uuid]}, publish: false)

      assert Common.filed_versions_counts!(g["slug"], [cat.uuid]) == %{cat.uuid => 1}
      assert Common.filed_versions_counts!(g["slug"], [Ecto.UUID.generate()]) == %{}
      assert Common.filed_versions_counts!(g["slug"], []) == %{}
    end

    test "filed_versions_counts!/2 counts a version once however often it lists a category, and ignores other groups" do
      g = Fx.group!()
      other = Fx.group!()
      cat = Fx.category!(g["slug"], "Dup")
      cat2 = Fx.category!(g["slug"], "Other")
      post = Fx.post!(g["slug"], %{title: "P", slug: "p"})
      file!(post[:uuid], 1, [cat.uuid, cat.uuid])

      {:ok, _} =
        Versions.create_new_version(g["slug"], elem(Posts.read_post_by_uuid(post[:uuid]), 1))

      file!(post[:uuid], 2, [cat.uuid, cat2.uuid])
      foreign = Fx.post!(other["slug"], %{title: "F", slug: "f"})
      file!(foreign[:uuid], 1, [cat.uuid])

      assert Common.filed_versions_counts!(g["slug"], [cat.uuid, cat2.uuid]) ==
               %{cat.uuid => 2, cat2.uuid => 1}
    end

    test "filed_versions_counts!/2 runs exactly one query for any number of uuids" do
      g = Fx.group!()
      cats = for n <- 1..3, do: Fx.category!(g["slug"], "Cat #{n}")
      uuids = Enum.map(cats, & &1.uuid)
      me = self()
      handler = "filed-counts-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        TestRepo.config()[:telemetry_prefix] ++ [:query],
        fn _event, _measurements, meta, _config -> send(me, {:query, meta.query}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      Common.filed_versions_counts!(g["slug"], uuids)
      assert_received {:query, _sql}
      refute_received {:query, _another}
    end
  end

  defp file!(post_uuid, number, category_uuids) do
    version = DBStorage.get_version(post_uuid, number)

    TestRepo.query!(
      "UPDATE phoenix_kit_publishing_versions SET data = jsonb_set(coalesce(data, '{}'::jsonb), '{category_uuids}', $1::jsonb) WHERE uuid = $2",
      [category_uuids, Ecto.UUID.dump!(version.uuid)]
    )
  end

  defp published_post!(group, slug, category_uuids) do
    post = Fx.post!(group["slug"], %{title: slug, slug: slug})
    file!(post[:uuid], 1, category_uuids)
    Fx.publish!(group["slug"], post[:uuid])
    post[:uuid]
  end

  describe "post_revision/3" do
    test "follows the values, not updated_at" do
      g = Fx.group!()
      post = Fx.post!(g["slug"], %{title: "One", slug: "one"})
      db = DBStorage.get_post_by_uuid(post[:uuid])
      version = DBStorage.get_version(post[:uuid], 1)
      [content] = DBStorage.list_contents(version.uuid)
      r1 = Common.post_revision(db, version, content)

      assert r1 ==
               Common.post_revision(db, version, %{content | updated_at: ~U[2030-01-01 00:00:00Z]})

      refute r1 == Common.post_revision(db, version, %{content | title: "Two"})
    end

    test "follows every component of the tuple it hashes" do
      g = Fx.group!()
      post = Fx.post!(g["slug"], %{title: "Parts", slug: "parts"})
      db = DBStorage.get_post_by_uuid(post[:uuid])
      version = DBStorage.get_version(post[:uuid], 1)
      [content] = DBStorage.list_contents(version.uuid)
      base = Common.post_revision(db, version, content)

      changed = [
        Common.post_revision(%{db | slug: "other"}, version, content),
        Common.post_revision(%{db | trashed_at: ~U[2030-01-01 00:00:00Z]}, version, content),
        Common.post_revision(%{db | active_version_uuid: Ecto.UUID.generate()}, version, content),
        Common.post_revision(%{db | post_date: ~D[2030-01-01]}, version, content),
        Common.post_revision(%{db | post_time: ~T[10:11:00]}, version, content),
        Common.post_revision(db, %{version | status: "archived"}, content),
        Common.post_revision(db, %{version | version_number: 9}, content),
        Common.post_revision(db, %{version | published_at: ~U[2030-01-01 00:00:00Z]}, content),
        Common.post_revision(db, %{version | data: %{"x" => 1}}, content),
        Common.post_revision(db, nil, content),
        Common.post_revision(db, version, %{content | language: "de"}),
        Common.post_revision(db, version, %{content | content: "other body"}),
        Common.post_revision(db, version, nil)
      ]

      for revision <- changed, do: refute(revision == base)
      assert length(Enum.uniq(changed)) == length(changed)
    end
  end

  describe "line_diff/2 bounds" do
    defp lines(n, prefix), do: Enum.map_join(1..n, "\n", &"#{prefix}#{&1}")
    defp timed(fun), do: elem(:timer.tc(fun), 0)

    test "one changed line in 40,000 is a line diff, without quadratic work" do
      old = lines(40_000, "line ")
      new = String.replace(old, "line 20000\n", "CHANGED\n")
      us = timed(fn -> send(self(), {:d, Common.line_diff(old, new)}) end)
      assert_received {:d, diff}
      assert us < 100_000
      assert diff["mode"] == "line"
      assert diff["text"] =~ "-line 20000"
      assert diff["text"] =~ "+CHANGED"
    end

    test "two unrelated 20,000-line bodies are coarse and truncated, without quadratic work" do
      us =
        timed(fn ->
          send(self(), {:d, Common.line_diff(lines(20_000, "a"), lines(20_000, "b"))})
        end)

      assert_received {:d, diff}
      assert us < 200_000
      assert diff["mode"] == "coarse" and diff["truncated"] == true
      assert diff["old_lines"] == 20_000 and diff["new_lines"] == 20_000
    end

    test "a 400-line total rewrite is a line diff, without quadratic work" do
      us = timed(fn -> send(self(), {:d, Common.line_diff(lines(400, "a"), lines(400, "b"))}) end)
      assert_received {:d, diff}
      assert us < 150_000
      assert diff["mode"] == "line"
    end

    test "the Myers cap is 400 lines: 400 is a line diff, 401 is coarse" do
      assert %{"mode" => "line"} = Common.line_diff(lines(400, "a"), lines(400, "b"))

      assert %{"mode" => "coarse", "old_lines" => 401, "new_lines" => 401} =
               Common.line_diff(lines(401, "a"), lines(401, "b"))

      assert %{"mode" => "coarse", "old_lines" => 401, "new_lines" => 3} =
               Common.line_diff(lines(401, "a"), lines(3, "b"))
    end

    test "the Myers branch shows two lines of context on each side of a change" do
      assert Common.line_diff("a\nb\nc\nd\ne\nf", "a\nB\nc\nd\ne\nf") == %{
               "mode" => "line",
               "text" => "@@ -1,4 +1,4 @@\n a\n-b\n+B\n c\n d",
               "hunks" => 1,
               "truncated" => false
             }

      assert Common.line_diff("a\nb\nc\nd\ne\nf\ng", "a\nb\nX\nd\ne\nf\ng")["text"] ==
               "@@ -1,5 +1,5 @@\n a\n b\n-c\n+X\n d\n e"
    end

    test "a coarse diff shows the first and last 10 lines of each middle and the omitted counts" do
      diff = Common.line_diff(lines(20_000, "a"), lines(20_000, "b"))
      assert diff["text"] =~ "-... 19980 lines omitted"
      assert diff["text"] =~ "+... 19980 lines omitted"
      assert diff["text"] =~ "-a1\n-a2\n"
      assert diff["text"] =~ "-a19999\n-a20000"
      assert diff["text"] =~ "+b1\n+b2\n"
      assert diff["text"] =~ "+b19999\n+b20000"
      refute diff["text"] =~ "a11\n"
      assert String.starts_with?(diff["text"], "@@ coarse @@\n")
    end

    test "a 500-line pure append is a line diff (one middle empty)" do
      old = lines(10, "keep ")
      assert %{"mode" => "line"} = Common.line_diff(old, old <> "\n" <> lines(500, "new "))
    end

    test "one changed line of 10,000 characters still gives a clipped, non-empty text" do
      diff = Common.line_diff("a\nb\nc", "a\n" <> String.duplicate("x", 10_000) <> "\nc")
      assert diff["text"] != ""
      assert diff["text"] =~ "... (+"
    end

    test "a changed line is clipped to exactly 300 characters plus the omitted count" do
      diff = Common.line_diff("a\nb\nc", "a\n" <> String.duplicate("x", 1_000) <> "\nc")
      clipped = diff["text"] |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "+x"))
      assert clipped == "+" <> String.duplicate("x", 300) <> "... (+700 chars)"
    end

    test "a coarse diff clips over-long lines, so its text is never emptied by the byte cap" do
      long = fn tag -> Enum.map_join(1..500, "\n", &(String.duplicate(tag, 5_000) <> "#{&1}")) end
      diff = Common.line_diff(long.("a"), long.("b"))
      assert diff["mode"] == "coarse"
      assert diff["text"] =~ "-" <> String.duplicate("a", 300) <> "... (+"
      assert byte_size(diff["text"]) <= 4096
    end

    test "text is capped at 4,096 bytes at a line boundary and says so, in line mode" do
      old = lines(10, "keep ")
      diff = Common.line_diff(old, old <> "\n" <> lines(2000, "new line "))
      assert diff["mode"] == "line" and diff["truncated"] == true and diff["hunks"] == 1
      assert byte_size(diff["text"]) <= 4096

      assert Enum.all?(
               String.split(diff["text"], "\n"),
               &String.starts_with?(&1, ["@@", " ", "+"])
             )

      assert diff["text"] =~ "+new line 1\n"
    end

    test "a pure insertion into an empty body is a line diff however long, and shows no phantom line" do
      assert Common.line_diff("", "a\nb") ==
               %{
                 "mode" => "line",
                 "text" => "@@ -0,0 +1,2 @@\n+a\n+b",
                 "hunks" => 1,
                 "truncated" => false
               }

      long = Common.line_diff("", lines(2000, "new line "))
      assert long["mode"] == "line" and long["truncated"] == true
      assert byte_size(long["text"]) <= 4096
      refute Map.has_key?(long, "old_lines")
      refute long["text"] =~ "\n-\n"
    end

    test "a pure deletion to an empty body is a line diff" do
      assert Common.line_diff("a\nb", "") ==
               %{
                 "mode" => "line",
                 "text" => "@@ -1,2 +0,0 @@\n-a\n-b",
                 "hunks" => 1,
                 "truncated" => false
               }

      assert %{"mode" => "line", "hunks" => 0, "text" => ""} = Common.line_diff("", "")
    end

    test "a body of 260,000 empty lines appended is bounded work and a capped line diff" do
      new = String.duplicate("\n", 260_000)
      us = timed(fn -> send(self(), {:d, Common.line_diff("", new)}) end)
      assert_received {:d, diff}
      assert us < 500_000
      assert diff["mode"] == "line" and diff["truncated"] == true
      assert byte_size(diff["text"]) <= 4096
      assert diff["text"] =~ "@@ -0,0 +1,260001 @@"
    end

    test "a pure append keeps context lines before it and counts them in the header" do
      diff = Common.line_diff("a\nb\nc", "a\nb\nc\nd")
      assert diff["text"] == "@@ -2,2 +2,3 @@\n b\n c\n+d"
    end

    test "every diff has mode, hunks and truncated; lines carry a space, - or + prefix" do
      diff = Common.line_diff("a\nb\nc\nd", "a\nB\nc\nd")
      assert %{"mode" => "line", "hunks" => 1, "truncated" => false, "text" => text} = diff
      assert text =~ "@@"
      assert Enum.all?(String.split(text, "\n"), &String.starts_with?(&1, ["@@", " ", "-", "+"]))
    end
  end

  describe "content_change/2" do
    test "carries bytes, hashes, head, tail, added_urls and the scan of the WHOLE new body, even when coarse" do
      old = lines(20_000, "a") <> "\n[x](https://old.example)"
      new = lines(20_000, "b") <> "\n[x](https://new.example) <script>x</script>"
      change = Common.content_change(old, new)
      assert change["diff"]["mode"] == "coarse"
      assert change["added_urls"] == ["new.example"]
      assert change["raw_html"]["dangerous"] == true
      assert change["from_sha256"] == Common.sha256(old)
      assert change["to_bytes"] == byte_size(new)
      assert change["head"] == String.slice(new, 0, 300)
      assert change["tail"] == String.slice(new, -300, 300)

      assert String.length(change["tail"]) == 300 and
               String.ends_with?(change["tail"], "</script>")

      assert change["added_urls_truncated"] == false
    end

    test "head and tail of a short body are the whole body, and a nil old body is empty" do
      change = Common.content_change(nil, "short body")
      assert change["head"] == "short body" and change["tail"] == "short body"
      assert change["from_bytes"] == 0 and change["from_sha256"] == Common.sha256("")
    end

    test "added_urls sees angle-bracket destinations, autolinks, bare URLs, references and scheme-relative links" do
      new =
        "[x](<https://evil.example/a>) <https://auto.example> https://bare.example/p, " <>
          "[r]: <https://q.example> [s](//rel.example/p) [t]: //ref-rel.example/z " <>
          "<img src=\"HTTP://Raw.Example/i.png\"> see https://dot.example."

      assert Common.content_change("", new)["added_urls"] == [
               "auto.example",
               "bare.example",
               "dot.example",
               "evil.example",
               "q.example",
               "raw.example",
               "ref-rel.example",
               "rel.example"
             ]
    end

    test "added_urls compares hosts case-insensitively, ignores empty hosts and plain // text" do
      old = "[a](https://Example.com/a)"

      new =
        "[a](https://EXAMPLE.com/b) [x](http://) [y](https:///p) [z](https://.) a // b and http:// alone"

      assert Common.content_change(old, new)["added_urls"] == []
    end

    test "added_urls is cut at 50 hosts and says so" do
      new =
        Enum.map_join(1..60, " ", &"[l](https://h#{String.pad_leading("#{&1}", 2, "0")}.example)")

      change = Common.content_change("", new)
      assert length(change["added_urls"]) == 50
      assert hd(change["added_urls"]) == "h01.example"
      assert change["added_urls_truncated"] == true

      assert Common.content_change("", Enum.join(Enum.take(String.split(new), 50), " "))[
               "added_urls_truncated"
             ] == false
    end

    test "added_urls are the hosts the new body has and the old one lacks, sorted, not all new hosts" do
      old = "[a](https://shared.example/a) ![i](http://kept.example/i.png)"

      new =
        "[a](https://shared.example/b) ![i](http://kept.example/i.png) [z](https://zeta.example/) " <>
          "[x](https://added.example/p)\n[ref]: https://refs.example/x"

      assert Common.content_change(old, new)["added_urls"] == [
               "added.example",
               "refs.example",
               "zeta.example"
             ]

      assert Common.content_change(new, old)["added_urls"] == []
    end
  end

  describe "check_text/3" do
    test "rejects NUL bytes, invalid UTF-8 and over-long bodies" do
      assert {:error, :validation_failed, _, %{errors: [%{path: "content"}]}} =
               Common.check_text("content", "a\u0000b", max: 100)

      assert {:error, :validation_failed, _, _} = Common.check_text("content", <<0xFF>>, max: 100)

      assert {:error, :validation_failed, _, %{errors: [%{reason: "content_too_large"}]}} =
               Common.check_text("content", String.duplicate("a", 11),
                 max: 10,
                 reason: "content_too_large"
               )

      assert {:error, :validation_failed, _, %{errors: [error]}} =
               Common.check_text("content", String.duplicate("a", 11), max: 10)

      refute Map.has_key?(error, :reason)

      assert :ok = Common.check_text("content", "fine", max: 10)
      assert :ok = Common.check_text("content", nil, max: 10)
    end
  end

  describe "check_text/3 character limit" do
    test ":max_chars counts characters, not bytes, and still refuses NUL and invalid UTF-8" do
      assert :ok = Common.check_text("title", String.duplicate("é", 10), max_chars: 10)

      assert {:error, :validation_failed, "is longer than 10 characters", %{errors: [error]}} =
               Common.check_text("title", String.duplicate("é", 11), max_chars: 10)

      assert error.path == "title" and error.limit == 10
      refute Map.has_key?(error, :reason)

      assert {:error, :validation_failed, _, %{errors: [%{reason: "too_long"}]}} =
               Common.check_text("title", "abc", max_chars: 2, reason: "too_long")

      assert {:error, :validation_failed, _, _} =
               Common.check_text("title", "a\u0000b", max_chars: 10)

      assert {:error, :validation_failed, _, _} =
               Common.check_text("title", <<0xFF>>, max_chars: 10)
    end
  end

  describe "check_text/3 default limit" do
    test "without :max the limit is the body cap, named in the message and the context" do
      cap = TextScan.max_body_bytes()

      assert {:error, :validation_failed, message, %{errors: [error]}} =
               Common.check_text("content", String.duplicate("a", cap + 1), [])

      assert message == "is longer than #{cap} bytes"
      assert error.limit == cap and error.path == "content"
      assert error.reason == "content_too_large"
      assert :ok = Common.check_text("content", String.duplicate("a", cap), [])
      assert {:error, :validation_failed, _, _} = Common.check_text("content", 12, [])
    end
  end

  describe "canonical_image_id/2" do
    test "an absent, null or empty value passes untouched" do
      assert {:ok, %{}} = Common.canonical_image_id(%{}, "og_image_id")

      assert {:ok, %{"og_image_id" => nil}} =
               Common.canonical_image_id(%{"og_image_id" => nil}, "og_image_id")

      assert {:ok, %{"og_image_id" => ""}} =
               Common.canonical_image_id(%{"og_image_id" => ""}, "og_image_id")
    end

    test "a UUID is lower-cased, anything else is a validation error on the field" do
      id = PhoenixKitPublishing.Test.MediaFixtures.file!().uuid

      assert {:ok, %{"og_image_id" => ^id}} =
               Common.canonical_image_id(%{"og_image_id" => String.upcase(id)}, "og_image_id")

      assert {:error, :validation_failed, _, %{errors: [%{path: "og_image_id"}]}} =
               Common.canonical_image_id(%{"og_image_id" => "nope"}, "og_image_id")

      assert {:error, :validation_failed, _, %{errors: [%{path: "og_image_id"}]}} =
               Common.canonical_image_id(%{"og_image_id" => 12}, "og_image_id")
    end
  end

  describe "locked_check/2" do
    test "a trashed locked row is refused whatever the confirmation" do
      check = Common.locked_check(ApiCase.ctx(%{confirmation_uuid: "x"}), fn _, _ -> true end)
      assert {:error, :post_trashed} = check.(%{trashed_at: ~U[2026-01-01 00:00:00Z]}, %{})
    end

    test "an unconfirmed call is refused when the condition holds, a confirmed or dry one passes" do
      live = fn _, _ -> true end

      assert {:error, :went_live} =
               Common.locked_check(ApiCase.ctx(), live).(%{trashed_at: nil}, %{})

      assert :ok =
               Common.locked_check(ApiCase.ctx(%{confirmation_uuid: "x"}), live).(
                 %{trashed_at: nil},
                 %{}
               )

      assert :ok =
               Common.locked_check(ApiCase.ctx(%{dry_run?: true}), live).(%{trashed_at: nil}, %{})

      assert :ok =
               Common.locked_check(ApiCase.ctx(), fn _, _ -> false end).(%{trashed_at: nil}, %{})
    end

    test "a context without :dry_run? is a real run: an unconfirmed call is refused when live" do
      ctx = Map.delete(ApiCase.ctx(), :dry_run?)

      assert {:error, :went_live} =
               Common.locked_check(ctx, fn _, _ -> true end).(%{trashed_at: nil}, %{})
    end

    test "an answer that is not exactly false counts as live" do
      for doubt <- [nil, :maybe, 0, "no"] do
        assert {:error, :went_live} =
                 Common.locked_check(ApiCase.ctx(), fn _, _ -> doubt end).(
                   %{trashed_at: nil},
                   %{}
                 )
      end
    end

    test "a closure that throws fails closed" do
      assert {:error, :locked_check_failed} =
               Common.locked_check(ApiCase.ctx(), fn _, _ -> throw(:boom) end).(
                 %{trashed_at: nil},
                 %{}
               )
    end

    test "a closure that raises fails closed" do
      boom = fn _, _ -> raise "boom" end

      assert {:error, :locked_check_failed} =
               Common.locked_check(ApiCase.ctx(), boom).(%{trashed_at: nil}, %{})
    end
  end
end
