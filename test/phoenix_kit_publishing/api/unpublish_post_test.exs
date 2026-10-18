defmodule PhoenixKit.Modules.Publishing.API.UnpublishPostTest do
  use PhoenixKit.DataCase, async: false

  import PhoenixKitPublishing.ActivityLogAssertions

  alias PhoenixKit.Modules.Publishing.API.Danger
  alias PhoenixKit.Modules.Publishing.{Groups, Posts}
  alias PhoenixKitPublishing.Test.ApiCase
  alias PhoenixKitPublishing.Test.ApiFixtures, as: Fx

  setup do
    Fx.languages!()
    g = Fx.group!()
    post = Fx.post!(g["slug"], %{title: "Hello", slug: "hello"})
    Fx.body!(g["slug"], post[:uuid], "# Body")
    Fx.publish!(g["slug"], post[:uuid])
    %{g: g, post: post}
  end

  defp unpublish(ctx, overrides \\ %{}),
    do: ApiCase.call("publishing.unpublish_post", %{"post" => Fx.ref(ctx.post)}, overrides)

  test "takes the live version down: the post is a draft again and the version keeps its published_at",
       ctx do
    published_at = Fx.version(ctx.post[:uuid]).published_at

    assert {:ok, %{"action" => "unpublished", "version" => 1, "post" => %{"status" => "draft"}}} =
             unpublish(ctx)

    assert Fx.db_post(ctx.post[:uuid]).active_version_uuid == nil
    version = Fx.version(ctx.post[:uuid])
    assert version.status == "draft" and version.published_at == published_at
    row = assert_activity_logged("publishing.post.unpublished", resource_uuid: ctx.post[:uuid])
    assert row.mode == "auto" and row.metadata["via"] == "api"
    assert row.metadata["tool"] == "publishing.unpublish_post"
  end

  test "a second call and a never-published post are not_published", ctx do
    assert {:ok, _} = unpublish(ctx)

    assert {:error, :validation_failed, _, %{errors: [%{reason: "not_published"}]}} =
             unpublish(ctx)

    fresh = Fx.post!(ctx.g["slug"], %{title: "Fresh", slug: "fresh"})

    assert {:error, :validation_failed, _, %{errors: [%{reason: "not_published"}]}} =
             ApiCase.call("publishing.unpublish_post", %{"post" => %{"id" => fresh[:uuid]}})
  end

  test "the preview lists the paths that stop resolving and leaves ALL tables unchanged", ctx do
    before = Fx.table_state()

    assert {:preview,
            %{
              "requires_confirmation" => true,
              "rows" => [
                %{"action" => "unpublish", "version" => 1, "public_paths_stop" => paths}
              ]
            }, _} = unpublish(ctx, %{dry_run?: true})

    assert Fx.table_state() == before
    assert Enum.any?(paths, &String.contains?(&1, "hello"))
  end

  test "a trashed post and a trashed group are refused", ctx do
    g2 = Fx.group!()
    p2 = Fx.post!(g2["slug"], %{title: "T", slug: "t"})
    Fx.publish!(g2["slug"], p2[:uuid])
    {:ok, _} = Groups.trash_group(g2["slug"])

    assert {:error, :validation_failed, _, %{errors: [%{reason: "group_trashed"}]}} =
             ApiCase.call("publishing.unpublish_post", %{"post" => %{"id" => p2[:uuid]}})

    {:ok, _} = Posts.trash_post(ctx.g["slug"], ctx.post[:uuid])

    assert {:error, :validation_failed, _, %{errors: [%{reason: "post_trashed"}]}} =
             unpublish(ctx)
  end

  test "after unpublishing, editing that version is no longer dangerous", ctx do
    {:ok, _} = unpublish(ctx)

    refute Danger.update_post(
             %{"post" => Fx.ref(ctx.post), "version" => 1, "title" => "x"},
             ApiCase.ctx(%{dry_run?: true})
           )
  end
end
