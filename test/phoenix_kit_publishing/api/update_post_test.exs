defmodule PhoenixKit.Modules.Publishing.API.UpdatePostTest do
  use PhoenixKit.DataCase, async: false

  import PhoenixKitPublishing.ActivityLogAssertions

  alias PhoenixKit.Modules.Publishing.{Groups, Posts, PublishingContent, PublishingPost}
  alias PhoenixKitPublishing.Test.ApiCase
  alias PhoenixKitPublishing.Test.ApiFixtures, as: Fx
  alias PhoenixKitPublishing.Test.Repo, as: TestRepo

  setup do
    Fx.languages!()
    g = Fx.group!()
    post = Fx.post!(g["slug"], %{title: "Hello", slug: "hello"})
    Fx.body!(g["slug"], post[:uuid], "# Body")
    %{g: g, post: post}
  end

  defp edit(ctx, fields, overrides \\ %{}),
    do:
      ApiCase.call(
        "publishing.update_post",
        Map.merge(%{"post" => Fx.ref(ctx.post)}, fields),
        overrides
      )

  defp body(ctx, language \\ "en-US"), do: Fx.content(ctx.post[:uuid], language).content

  test "a draft edit updates title and content, keeps the slug and never publishes", ctx do
    assert {:ok, %{"action" => "updated", "changed" => changed}} =
             edit(ctx, %{"title" => "New", "content" => "new body"})

    assert changed |> Enum.map(& &1["field"]) |> Enum.sort() == ["content", "title"]
    assert Enum.all?(changed, &(&1["scope"] == "language"))
    db = Fx.db_post(ctx.post[:uuid])
    assert db.slug == "hello" and db.active_version_uuid == nil
    assert Fx.version(ctx.post[:uuid]).status == "draft"
    assert body(ctx) == "new body"
  end

  test "status, published_at, url_slug, tags and force are rejected by the schema", ctx do
    for key <- ~w(status published_at url_slug tags force) do
      assert {:error, :validation_failed, _, _} = edit(ctx, %{key => "x", "title" => "T"}), key
    end
  end

  test "no field at all is empty_update", ctx do
    assert {:error, :validation_failed, _, %{errors: [%{reason: "empty_update"}]}} =
             edit(ctx, %{})
  end

  test "an update that changes nothing answers unchanged and writes no activity row", ctx do
    {:ok, _} = edit(ctx, %{"title" => "Same"})
    n = length(list_activities())
    assert {:ok, %{"action" => "unchanged"}} = edit(ctx, %{"title" => "Same"})
    assert length(list_activities()) == n
  end

  test "description is version-level: it applies to every language and is reported with scope version",
       ctx do
    Fx.translation!(ctx.g["slug"], ctx.post[:uuid], "de-DE", "Hallo", "Inhalt")

    assert {:ok, %{"changed" => [%{"field" => "description", "scope" => "version"}]}} =
             edit(ctx, %{"description" => "d", "language" => "de-DE"})

    assert Fx.version(ctx.post[:uuid]).data["description"] == "d"

    assert {:ok, %{"fields" => %{"description" => "d"}}} =
             ApiCase.call("publishing.get_post", %{
               "post" => Fx.ref(ctx.post),
               "language" => "en-US"
             })
  end

  test "og_title alone keeps the stored og description and image", ctx do
    image = Ecto.UUID.generate()
    {:ok, _} = edit(ctx, %{"og_title" => "T1", "og_description" => "D1", "og_image_id" => image})
    {:ok, _} = edit(ctx, %{"og_title" => "T2"})
    og = PublishingContent.get_og(Fx.content(ctx.post[:uuid]))
    assert og["title"] == "T2" and og["description"] == "D1" and og["image_uuid"] == image
  end

  test "category_ids of the group are accepted, of another group refused", ctx do
    own = Fx.category!(ctx.g["slug"], "Own")
    foreign = Fx.category!(Fx.group!()["slug"], "Foreign")
    assert {:ok, %{"action" => "updated"}} = edit(ctx, %{"category_ids" => [own.uuid]})
    assert Fx.version(ctx.post[:uuid]).data["category_uuids"] == [own.uuid]

    assert {:error, :validation_failed, _, %{errors: [%{reason: "unknown_category"}]}} =
             edit(ctx, %{"category_ids" => [foreign.uuid]})
  end

  test "null clears a text field (stored as an empty string)", ctx do
    {:ok, _} = edit(ctx, %{"description" => "d"})

    assert {:ok, %{"changed" => [%{"field" => "description"}]}} =
             edit(ctx, %{"description" => nil})

    assert Fx.version(ctx.post[:uuid]).data["description"] == ""
  end

  test "a language with no row is language_missing and the primary body is untouched", ctx do
    assert {:error, :validation_failed, _, %{errors: [%{reason: "language_missing"}]}} =
             edit(ctx, %{"title" => "X", "language" => "de-DE"})

    assert body(ctx) == "# Body"
  end

  test "a language that is no longer enabled is language_not_enabled with allowed",
       ctx do
    Fx.translation!(ctx.g["slug"], ctx.post[:uuid], "de-DE", "Hallo", "Inhalt")
    Fx.languages!(["en-US"])

    assert {:error, :validation_failed, _,
            %{errors: [%{reason: "language_not_enabled", allowed: ["en-US"]}]}} =
             edit(ctx, %{"title" => "X", "language" => "de-DE"})
  end

  test "slug: renames in a slug group; invalid, taken by another post and timestamp groups are refused; the same slug is no change",
       ctx do
    assert {:ok, %{"changed" => [%{"field" => "slug", "scope" => "post"}]}} =
             edit(ctx, %{"slug" => "renamed"})

    assert Fx.db_post(ctx.post[:uuid]).slug == "renamed"

    assert {:error, :validation_failed, _, %{errors: [%{reason: "invalid_slug"}]}} =
             edit(ctx, %{"slug" => "Not Valid"})

    Fx.post!(ctx.g["slug"], %{title: "Other", slug: "other"})

    assert {:error, :validation_failed, _, %{errors: [%{reason: "slug_taken"}]}} =
             edit(ctx, %{"slug" => "other"})

    assert {:ok, %{"action" => "unchanged"}} = edit(ctx, %{"slug" => "renamed"})

    ts = Fx.group!(mode: "timestamp")
    stamp = Fx.post!(ts["slug"], %{title: "Stamp"})

    assert {:error, :validation_failed, _, %{errors: [%{reason: "slug_not_allowed"}]}} =
             ApiCase.call("publishing.update_post", %{
               "post" => %{"id" => stamp[:uuid]},
               "slug" => "x"
             })
  end

  test "no draft and no explicit version is no_draft_version; an explicit live version needs the confirmation context",
       ctx do
    Fx.publish!(ctx.g["slug"], ctx.post[:uuid])

    assert {:error, :validation_failed, _, %{errors: [%{reason: "no_draft_version"}]}} =
             edit(ctx, %{"title" => "X"})

    assert {:ok, %{"action" => "updated"}} =
             edit(ctx, %{"title" => "X", "version" => 1}, %{confirmation_uuid: "c"})
  end

  test "a trashed post is post_trashed and a trashed group is group_trashed", ctx do
    {:ok, _} = Posts.trash_post(ctx.g["slug"], ctx.post[:uuid])

    assert {:error, :validation_failed, _, %{errors: [%{reason: "post_trashed"}]}} =
             edit(ctx, %{"title" => "X"})

    g2 = Fx.group!()
    p2 = Fx.post!(g2["slug"], %{title: "T", slug: "t"})
    {:ok, _} = Groups.trash_group(g2["slug"])

    assert {:error, :validation_failed, _, %{errors: [%{reason: "group_trashed"}]}} =
             ApiCase.call("publishing.update_post", %{
               "post" => %{"id" => p2[:uuid]},
               "title" => "X"
             })
  end

  test "a NUL byte in any text field is a validation error with the path, never a 500",
       ctx do
    for field <- ~w(title content description seo_title excerpt og_title og_description) do
      assert {:error, :validation_failed, _, %{errors: [%{path: ^field}]}} =
               edit(ctx, %{field => "a\u0000b"})
    end
  end

  test "content: 262,144 bytes is accepted, 262,145 is content_too_large", ctx do
    ok = String.duplicate("a", 262_144)
    assert {:ok, %{"action" => "updated"}} = edit(ctx, %{"content" => ok})

    assert {:error, :validation_failed, _, %{errors: [%{reason: "content_too_large"}]}} =
             edit(ctx, %{"content" => ok <> "a"})
  end

  test "if_revision: a stale value is revision_mismatch with current_revision, the current one passes",
       ctx do
    {:ok, %{"revision" => rev}} =
      ApiCase.call("publishing.get_post", %{"post" => Fx.ref(ctx.post)})

    {:ok, _} = edit(ctx, %{"title" => "Changed"})

    assert {:error, :revision_mismatch, _, %{current_revision: current}} =
             edit(ctx, %{"title" => "Again", "if_revision" => rev})

    assert current =~ ~r/\A[0-9a-f]{64}\z/

    assert {:ok, %{"action" => "updated"}} =
             edit(ctx, %{"title" => "Again", "if_revision" => current})
  end

  test "the activity row is auto, attributed, and lists field names but never values", ctx do
    {:ok, _} = edit(ctx, %{"title" => "Secret Title 123", "description" => "Secret Desc"})

    row =
      Enum.find(
        list_activities(),
        &(&1.action == "publishing.post.updated" and &1.mode == "auto")
      )

    assert row.metadata["via"] == "api" and row.metadata["tool"] == "publishing.update_post"
    assert Enum.sort(row.metadata["fields"]) == ["description", "title"]
    refute inspect(row.metadata) =~ "Secret"
  end

  test "a dry run leaves ALL tables unchanged and previews live, public and scope", ctx do
    before = Fx.table_state()

    assert {:preview, preview, fingerprint} =
             edit(ctx, %{"title" => "New", "content" => "# Body\n\nadded line"}, %{dry_run?: true})

    assert Fx.table_state() == before

    assert [%{"action" => "update", "live" => false, "public" => "none", "changes" => changes}] =
             preview["rows"]

    assert %{"scope" => "language", "from" => "Hello", "to" => "New"} = changes["title"]
    assert changes["content"]["scope"] == "language"
    assert changes["content"]["diff"]["text"] =~ "+added line"
    assert preview["requires_confirmation"] == false
    assert fingerprint =~ ~r/\A[0-9a-f]{64}\z/
  end

  test "a dry run does not heal a stale post, while the module's own read does", ctx do
    # A stale pointer: active_version_uuid names a version that is still a draft.
    version = Fx.version(ctx.post[:uuid])
    import Ecto.Query

    TestRepo.update_all(from(p in PublishingPost, where: p.uuid == ^ctx.post[:uuid]),
      set: [active_version_uuid: version.uuid]
    )

    stale = Fx.db_post(ctx.post[:uuid])
    assert stale.active_version_uuid == version.uuid

    assert {:preview, _, _} = edit(ctx, %{"title" => "New"}, %{dry_run?: true})
    assert Fx.db_post(ctx.post[:uuid]).active_version_uuid == version.uuid

    {:ok, _} = Posts.read_post_by_uuid(ctx.post[:uuid])

    assert Fx.db_post(ctx.post[:uuid]).active_version_uuid == nil,
           "the fixture is not stale: this test would be vacuous"
  end

  test "the preview of a body change shows the changed line; beyond 4 KB the diff says truncated",
       ctx do
    long = Enum.map_join(1..400, "\n", &"line #{&1}")
    Fx.body!(ctx.g["slug"], ctx.post[:uuid], long)
    new = String.replace(long, "line 200\n", "line 200 CHANGED\n")

    assert {:preview, %{"rows" => [%{"changes" => %{"content" => %{"diff" => diff}}}]}, _} =
             edit(ctx, %{"content" => new}, %{dry_run?: true})

    assert diff["text"] =~ "+line 200 CHANGED" and diff["truncated"] == false

    rewritten =
      Enum.map_join(
        1..400,
        "\n",
        &"completely different line number #{&1} with some padding text"
      )

    assert {:preview, %{"rows" => [%{"changes" => %{"content" => %{"diff" => big}}}]}, _} =
             edit(ctx, %{"content" => rewritten}, %{dry_run?: true})

    assert big["truncated"] == true and byte_size(big["text"]) <= 4096
  end

  test "the fingerprint follows the post state and the new body, not the diff text", ctx do
    {:preview, _, f1} = edit(ctx, %{"content" => "new A"}, %{dry_run?: true})
    {:preview, _, f1b} = edit(ctx, %{"content" => "new A"}, %{dry_run?: true})
    {:preview, _, f2} = edit(ctx, %{"content" => "new B"}, %{dry_run?: true})
    assert f1 == f1b and f1 != f2
    Fx.body!(ctx.g["slug"], ctx.post[:uuid], "someone else edited")
    {:preview, _, f3} = edit(ctx, %{"content" => "new A"}, %{dry_run?: true})
    assert f3 != f1
  end
end
