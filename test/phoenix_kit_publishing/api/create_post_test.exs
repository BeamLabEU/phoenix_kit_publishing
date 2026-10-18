defmodule PhoenixKit.Modules.Publishing.API.CreatePostTest do
  use PhoenixKit.DataCase, async: false

  import PhoenixKitPublishing.ActivityLogAssertions

  alias PhoenixKit.Modules.Publishing.{DBStorage, Groups, Posts}
  alias PhoenixKitPublishing.Test.ApiCase
  alias PhoenixKitPublishing.Test.ApiFixtures, as: Fx

  setup do
    Fx.languages!()
    %{g: Fx.group!()}
  end

  defp create(g, extra),
    do:
      ApiCase.call(
        "publishing.create_post",
        Map.merge(%{"group" => g["slug"], "title" => "Hello"}, extra)
      )

  test "creates a draft with version 1 and the primary-language body; created_by is the key owner" do
    user = Fx.user!()
    g = Fx.group!()

    assert {:ok, %{"action" => "created", "post" => post}} =
             ApiCase.call(
               "publishing.create_post",
               %{
                 "group" => g["slug"],
                 "title" => "Hello",
                 "content" => "# Hi",
                 "slug" => "hello"
               },
               %{actor: %{ApiCase.ctx().actor | user_uuid: user.uuid}}
             )

    assert post["status"] == "draft" and post["latest_version"] == 1 and
             post["languages"] == ["en-US"]

    refute Map.has_key?(post, "title") or Map.has_key?(post, "slug") or
             Map.has_key?(post, "public_paths")

    db = DBStorage.get_post_by_uuid(post["id"])
    assert db.slug == "hello" and db.created_by_uuid == user.uuid
    [content] = DBStorage.list_contents(DBStorage.get_version(post["id"], 1).uuid)
    assert content.title == "Hello" and content.content == "# Hi"
    row = assert_activity_logged("publishing.post.created", resource_uuid: post["id"])
    assert row.mode == "auto" and row.metadata["via"] == "api"
    assert row.metadata["tool"] == "publishing.create_post"
  end

  test "a title like pk_sale does not put free text into the answer" do
    assert {:ok, body} = create(Fx.group!(), %{"title" => "pk_sale"})
    refute inspect(body) =~ "pk_sale"
  end

  test "a timestamp-mode post: slug is refused, the post has no slug and is addressed by id" do
    ts = Fx.group!(mode: "timestamp")

    assert {:error, :validation_failed, _, %{errors: [%{reason: "slug_not_allowed"}]}} =
             create(ts, %{"slug" => "x"})

    assert {:ok, %{"post" => %{"id" => id, "mode" => "timestamp"}}} = create(ts, %{})
    assert DBStorage.get_post_by_uuid(id).slug in [nil, ""]
  end

  test "slug rules: invalid, reserved language code, reserved route word, taken (live and trashed)",
       %{g: g} do
    assert {:error, :validation_failed, _, %{errors: [%{reason: "invalid_slug"}]}} =
             create(g, %{"slug" => "Not A Slug"})

    # Language codes are dialect codes ("en-US"), which the lowercase slug pattern refuses as
    # invalid_slug; a language configured with a bare lowercase code is what a slug can collide with.
    Fx.languages!(["en-US", "de-DE", "xx"])

    assert {:error, :validation_failed, _, %{errors: [%{reason: "reserved_language_code"}]}} =
             create(g, %{"slug" => "xx"})

    assert {:error, :validation_failed, _, %{errors: [%{reason: "reserved_route_word"}]}} =
             create(g, %{"slug" => "admin"})

    assert {:ok, %{"post" => %{"id" => id}}} = create(g, %{"slug" => "taken"})

    assert {:error, :validation_failed, _, %{errors: [%{reason: "slug_taken"}]}} =
             create(g, %{"slug" => "taken"})

    {:ok, _} = Posts.trash_post(g["slug"], id)

    assert {:error, :validation_failed, _, %{errors: [%{reason: "slug_taken"} = e]} = ctx} =
             create(g, %{"slug" => "taken"})

    assert ctx[:trashed] == true or e[:trashed] == true
  end

  test "title rules: blank title is title_required; over 500 is refused by the schema", %{g: g} do
    assert {:error, :validation_failed, _, %{errors: [%{reason: "title_required"}]}} =
             create(g, %{"title" => "   "})

    assert {:error, :validation_failed, _, _} =
             create(g, %{"title" => String.duplicate("a", 501)})
  end

  test "a NUL byte or invalid text is a validation error, not a 500 (Review Focus 1)", %{g: g} do
    assert {:error, :validation_failed, _, %{errors: [%{path: "title"}]}} =
             create(g, %{"title" => "a\u0000b"})

    assert {:error, :validation_failed, _, %{errors: [%{path: "content"}]}} =
             create(g, %{"content" => "a\u0000b"})
  end

  test "content: 262,144 bytes is accepted, 262,145 is content_too_large", %{g: g} do
    ok = String.duplicate("a", 262_144)
    assert {:ok, _} = create(g, %{"content" => ok})

    assert {:error, :validation_failed, _, %{errors: [%{reason: "content_too_large"}]}} =
             create(g, %{"content" => ok <> "a"})
  end

  test "a trashed or unknown group is refused", %{g: g} do
    {:ok, _} = Groups.trash_group(g["slug"])

    assert {:error, :validation_failed, _, %{errors: [%{reason: "group_trashed"}]}} =
             create(g, %{})

    assert {:error, :not_found, _, _} =
             ApiCase.call("publishing.create_post", %{"group" => "nope", "title" => "x"})
  end

  test "a dry run writes nothing (all tables and the activity log) and previews the content with the text scan",
       %{g: g} do
    before = Fx.table_state()

    assert {:preview, preview, fingerprint} =
             ApiCase.call(
               "publishing.create_post",
               %{"group" => g["slug"], "title" => "T", "content" => "<b>x</b>", "slug" => "dry"},
               %{dry_run?: true}
             )

    assert Fx.table_state() == before
    assert preview["requires_confirmation"] == true
    assert [%{"content" => %{"raw_html" => %{"dangerous" => true}}}] = preview["rows"]
    assert fingerprint =~ ~r/\A[0-9a-f]{64}\z/

    assert {:preview, plain, _} =
             ApiCase.call(
               "publishing.create_post",
               %{"group" => g["slug"], "title" => "T", "content" => "plain"},
               %{dry_run?: true}
             )

    assert plain["requires_confirmation"] == false
  end

  test "idempotent only with a key: two plain calls make two posts", %{g: g} do
    {:ok, %{"post" => %{"id" => a}}} = create(g, %{})
    {:ok, %{"post" => %{"id" => b}}} = create(g, %{})
    refute a == b
  end
end
