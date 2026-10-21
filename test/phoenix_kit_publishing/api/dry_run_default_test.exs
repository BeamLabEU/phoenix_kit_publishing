defmodule PhoenixKit.Modules.Publishing.API.DryRunDefaultTest do
  # A context without a `:dry_run?` key (a core without the confirmation flow never sets it) is a
  # real run: every tool that has a preview must write, not preview, when the key is absent.
  use PhoenixKit.DataCase, async: false

  alias PhoenixKitPublishing.Test.ApiCase
  alias PhoenixKitPublishing.Test.ApiFixtures, as: Fx

  setup do
    Fx.languages!(["en-US", "de-DE"])
    g = Fx.group!()
    post = Fx.post!(g["slug"], %{title: "Hello", slug: "hello"})
    Fx.body!(g["slug"], post[:uuid], "# Body")
    %{g: g, post: post}
  end

  # The dry run of the input is a preview (the input reaches the preview branch), and the same
  # input without the key is not.
  defp assert_real_run(tool, input) do
    assert {:preview, _rows, _fingerprint} = ApiCase.call(tool, input, %{dry_run?: true})

    result = ApiCase.call_without_dry_run_key(tool, input)
    refute match?({:preview, _, _}, result), "#{tool} previewed without a :dry_run? key"
    result
  end

  test "update_post and set_translation", ctx do
    assert {:ok, %{"action" => "updated"}} =
             assert_real_run("publishing.update_post", %{
               "post" => Fx.ref(ctx.post),
               "title" => "New"
             })

    assert Fx.content(ctx.post[:uuid]).title == "New"

    assert {:ok, %{"action" => "created"}} =
             assert_real_run("publishing.set_translation", %{
               "post" => Fx.ref(ctx.post),
               "language" => "de-DE",
               "title" => "Hallo",
               "content" => "Inhalt"
             })

    assert Fx.content(ctx.post[:uuid], "de-DE").title == "Hallo"
  end

  test "create_post and create_version", ctx do
    assert {:ok, %{"action" => "created"}} =
             assert_real_run("publishing.create_post", %{
               "group" => ctx.g["slug"],
               "title" => "Two"
             })

    assert {:ok, %{"action" => "created", "version" => 2}} =
             assert_real_run("publishing.create_version", %{"post" => Fx.ref(ctx.post)})
  end

  test "publish_post and unpublish_post", ctx do
    assert {:ok, %{"action" => "published"}} =
             assert_real_run("publishing.publish_post", %{"post" => Fx.ref(ctx.post)})

    assert Fx.db_post(ctx.post[:uuid]).active_version_uuid != nil

    assert {:ok, %{"action" => "unpublished"}} =
             assert_real_run("publishing.unpublish_post", %{"post" => Fx.ref(ctx.post)})

    assert Fx.db_post(ctx.post[:uuid]).active_version_uuid == nil
  end

  test "schedule_post" do
    tg = Fx.group!(mode: "timestamp")
    post = Fx.post!(tg["slug"], %{title: "Soon"})
    Fx.body!(tg["slug"], post[:uuid], "# Body")
    publish_at = "#{Date.utc_today() |> Date.add(10)}T09:30"

    assert {:ok, %{"action" => "scheduled"}} =
             assert_real_run("publishing.schedule_post", %{
               "post" => Fx.ref(post),
               "publish_at" => publish_at
             })

    assert Fx.db_post(post[:uuid]).active_version_uuid != nil
  end

  test "trash_posts and restore_posts", ctx do
    assert {:ok, %{"summary" => %{"removed" => 1}}} =
             assert_real_run("publishing.trash_posts", %{"posts" => [Fx.ref(ctx.post)]})

    assert Fx.db_post(ctx.post[:uuid]).trashed_at != nil

    assert {:ok, %{"summary" => %{"restored" => 1}}} =
             assert_real_run("publishing.restore_posts", %{"posts" => [Fx.ref(ctx.post)]})

    assert Fx.db_post(ctx.post[:uuid]).trashed_at == nil
  end

  test "upsert_categories and delete_categories", ctx do
    assert {:ok, %{"results" => [%{"action" => "created"}]}} =
             assert_real_run("publishing.upsert_categories", %{
               "group" => ctx.g["slug"],
               "categories" => [%{"slug" => "news", "name" => "News"}]
             })

    assert {:ok, %{"summary" => %{"removed" => 1}}} =
             assert_real_run("publishing.delete_categories", %{
               "group" => ctx.g["slug"],
               "refs" => [%{"slug" => "news"}]
             })
  end

  test "upsert_groups, trash_groups and restore_groups", ctx do
    assert {:ok, %{"results" => [%{"action" => "created"}]}} =
             assert_real_run("publishing.upsert_groups", %{
               "groups" => [%{"slug" => "docs", "name" => "Docs", "mode" => "slug"}]
             })

    assert {:ok, %{"summary" => %{"removed" => 1}}} =
             assert_real_run("publishing.trash_groups", %{
               "groups" => [%{"slug" => ctx.g["slug"]}]
             })

    assert {:ok, %{"summary" => %{"restored" => 1}}} =
             assert_real_run("publishing.restore_groups", %{
               "groups" => [%{"slug" => ctx.g["slug"]}]
             })
  end
end
