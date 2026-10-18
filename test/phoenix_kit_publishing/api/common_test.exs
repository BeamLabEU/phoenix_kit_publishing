defmodule PhoenixKit.Modules.Publishing.API.CommonTest do
  use PhoenixKitPublishing.DataCase, async: false

  alias PhoenixKit.Modules.Publishing.API.Common
  alias PhoenixKit.Modules.Publishing.{DBStorage, Posts}
  alias PhoenixKitPublishing.Test.ApiCase
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

    test "a database error raises instead of answering an empty result" do
      g = Fx.group!()

      TestRepo.query!(
        "ALTER TABLE phoenix_kit_publishing_categories RENAME TO phoenix_kit_publishing_categories_x"
      )

      assert_raise Postgrex.Error, fn -> Common.categories!(g["slug"]) end
      assert_raise Postgrex.Error, fn -> Common.category_tree!(g["slug"]) end
      # rolled back with the sandbox transaction
    end

    test "filed_versions_counts!/2 counts versions of the group that name each category, in one query" do
      g = Fx.group!()
      cat = Fx.category!(g["slug"], "Filed")
      post = Fx.post!(g["slug"], %{title: "P", slug: "p"})
      {:ok, p} = Posts.read_post_by_uuid(post[:uuid])

      {:ok, _} =
        Posts.update_post(g["slug"], p, %{"category_uuids" => [cat.uuid]}, publish: false)

      assert Common.filed_versions_counts!(g["slug"], [cat.uuid]) == %{cat.uuid => 1}
      assert Common.filed_versions_counts!(g["slug"], [Ecto.UUID.generate()]) == %{}
    end
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
  end

  describe "line_diff/2 bounds (spec §9.12)" do
    defp lines(n, prefix), do: Enum.map_join(1..n, "\n", &"#{prefix}#{&1}")
    defp timed(fun), do: elem(:timer.tc(fun), 0)

    test "one changed line in 40,000 is a line diff in well under 100 ms" do
      old = lines(40_000, "line ")
      new = String.replace(old, "line 20000\n", "CHANGED\n")
      us = timed(fn -> send(self(), {:d, Common.line_diff(old, new)}) end)
      assert_received {:d, diff}
      assert us < 100_000
      assert diff["mode"] == "line"
      assert diff["text"] =~ "-line 20000"
      assert diff["text"] =~ "+CHANGED"
    end

    test "two unrelated 20,000-line bodies are coarse, truncated, under 200 ms" do
      us =
        timed(fn ->
          send(self(), {:d, Common.line_diff(lines(20_000, "a"), lines(20_000, "b"))})
        end)

      assert_received {:d, diff}
      assert us < 200_000
      assert diff["mode"] == "coarse" and diff["truncated"] == true
      assert diff["old_lines"] == 20_000 and diff["new_lines"] == 20_000
    end

    test "a 400-line total rewrite is a line diff in under 150 ms" do
      us = timed(fn -> send(self(), {:d, Common.line_diff(lines(400, "a"), lines(400, "b"))}) end)
      assert_received {:d, diff}
      assert us < 150_000
      assert diff["mode"] == "line"
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

    test "text is capped at 4,096 bytes at a line boundary and says so" do
      diff = Common.line_diff("", lines(2000, "new line "))
      assert byte_size(diff["text"]) <= 4096 and diff["truncated"] == true
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
      assert String.length(change["head"]) <= 300 and String.length(change["tail"]) <= 300
    end

    test "the fingerprint never depends on the diff text (same fingerprint input, different diff modes)" do
      assert Common.fingerprint({Common.sha256("a")}) == Common.fingerprint({Common.sha256("a")})
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

      assert :ok = Common.check_text("content", "fine", max: 10)
      assert :ok = Common.check_text("content", nil, max: 10)
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

    test "a closure that raises fails closed" do
      boom = fn _, _ -> raise "boom" end

      assert {:error, :locked_check_failed} =
               Common.locked_check(ApiCase.ctx(), boom).(%{trashed_at: nil}, %{})
    end
  end
end
