defmodule PhoenixKit.Modules.Publishing.API.RestorePostsTest do
  use PhoenixKit.DataCase, async: false

  import PhoenixKitPublishing.ActivityLogAssertions

  alias PhoenixKit.Modules.Publishing.API.Danger
  alias PhoenixKit.Modules.Publishing.{DBStorage, Groups, Posts}
  alias PhoenixKitPublishing.Test.ApiCase
  alias PhoenixKitPublishing.Test.ApiFixtures, as: Fx
  alias PhoenixKitPublishing.Test.Repo, as: TestRepo

  defp ctx, do: ApiCase.ctx(%{dry_run?: true})

  setup do
    Fx.languages!()
    g = Fx.group!()
    draft = Fx.post!(g["slug"], %{title: "Draft", slug: "draft"})
    live = Fx.post!(g["slug"], %{title: "Live", slug: "live"})
    Fx.body!(g["slug"], live[:uuid], "# Live")
    Fx.publish!(g["slug"], live[:uuid])
    {:ok, _} = Posts.trash_post(g["slug"], draft[:uuid])
    {:ok, _} = Posts.trash_post(g["slug"], live[:uuid])
    %{g: g, draft: draft, live: live}
  end

  defp restore(refs, overrides \\ %{}),
    do: ApiCase.call("publishing.restore_posts", %{"posts" => refs}, overrides)

  defp slug_ref(ctx, slug), do: %{"group" => ctx.g["slug"], "slug" => slug}

  test "restores by SLUG; the round trip keeps the live pointer and the public post resolves again",
       ctx do
    live_version = Fx.db_post(ctx.live[:uuid]).active_version_uuid

    assert {:ok, %{"summary" => %{"restored" => 2}}} =
             restore([slug_ref(ctx, "draft"), slug_ref(ctx, "live")])

    assert Fx.db_post(ctx.live[:uuid]).trashed_at == nil
    assert Fx.db_post(ctx.live[:uuid]).active_version_uuid == live_version
    assert DBStorage.get_post(ctx.g["slug"], "live") != nil
    row = assert_activity_logged("publishing.post.restored", resource_uuid: ctx.live[:uuid])
    assert row.mode == "auto" and row.metadata["via"] == "api"
  end

  test "a post that is not in the trash is unchanged; duplicates are a row error; a post in a trashed group is group_trashed",
       ctx do
    {:ok, _} = restore([Fx.ref(ctx.draft)])
    assert {:ok, %{"results" => [%{"action" => "unchanged"}]}} = restore([Fx.ref(ctx.draft)])

    assert {:ok, %{"results" => [_, %{"error" => %{"code" => "invalid_ref"}}]}} =
             restore([Fx.ref(ctx.live), slug_ref(ctx, "live")])

    {:ok, _} = Posts.trash_post(ctx.g["slug"], ctx.live[:uuid])
    {:ok, _} = Groups.trash_group(ctx.g["slug"])

    assert {:ok, %{"results" => [%{"error" => %{"code" => "group_trashed"}}]}} =
             restore([Fx.ref(ctx.live)])
  end

  test "more than 50 refs are refused by max_items", ctx do
    assert {:error, :validation_failed, _, _} =
             restore(for(_ <- 1..51, do: Fx.ref(ctx.draft)))
  end

  describe "Danger.restore_posts/2" do
    test "false for a trashed draft, true for a trashed post with an active version", ctx do
      refute Danger.restore_posts(%{"posts" => [Fx.ref(ctx.draft)]}, ctx())
      assert Danger.restore_posts(%{"posts" => [Fx.ref(ctx.live)]}, ctx())
      assert Danger.restore_posts(%{"posts" => [Fx.ref(ctx.draft), Fx.ref(ctx.live)]}, ctx())
    end

    test "false for posts that are not trashed", ctx do
      {:ok, _} = restore([Fx.ref(ctx.live)])
      refute Danger.restore_posts(%{"posts" => [Fx.ref(ctx.live)]}, ctx())
    end

    test "fail closed: an unresolvable ref, an empty ref and a lookup error answer true", ctx do
      assert Danger.restore_posts(%{"posts" => [%{"id" => Ecto.UUID.generate()}]}, ctx())
      assert Danger.restore_posts(%{"posts" => [%{}]}, ctx())

      TestRepo.query!(
        "ALTER TABLE phoenix_kit_publishing_posts RENAME TO phoenix_kit_publishing_posts_x"
      )

      assert Danger.restore_posts(%{"posts" => [Fx.ref(ctx.draft)]}, ctx())
    end
  end

  test "the preview says whether a post becomes visible; ALL tables unchanged; the flag follows the danger function",
       ctx do
    before = Fx.table_state()

    assert {:preview, %{"requires_confirmation" => true, "rows" => [draft, live]}, _} =
             restore([Fx.ref(ctx.draft), Fx.ref(ctx.live)], %{dry_run?: true})

    assert Fx.table_state() == before
    assert draft["becomes_visible"] == false and live["becomes_visible"] == true
    assert live["changes"]["status"] == %{"from" => "trashed", "to" => "published"}

    assert {:preview, %{"requires_confirmation" => false}, _} =
             restore([Fx.ref(ctx.draft)], %{dry_run?: true})
  end

  test "the fingerprint follows an edit of the text that becomes visible", ctx do
    assert {:preview, _, f1} = restore([Fx.ref(ctx.live)], %{dry_run?: true})
    assert {:preview, _, ^f1} = restore([Fx.ref(ctx.live)], %{dry_run?: true})

    # Posts in the trash cannot be read for editing: take the post out, edit it and trash it again.
    {:ok, _} = Posts.restore_post(ctx.g["slug"], ctx.live[:uuid])
    Fx.body!(ctx.g["slug"], ctx.live[:uuid], "edited", 1)
    {:ok, _} = Posts.trash_post(ctx.g["slug"], ctx.live[:uuid])

    assert {:preview, _, f2} = restore([Fx.ref(ctx.live)], %{dry_run?: true})
    assert f1 != f2
  end

  test "a trashed post that is scheduled ahead is dangerous (fail closed) but not visible yet" do
    ts = Fx.group!(mode: "timestamp")
    p = Fx.post!(ts["slug"], %{title: "Soon"})
    Fx.body!(ts["slug"], p[:uuid], "x")

    {:ok, _} =
      ApiCase.call("publishing.schedule_post", %{
        "post" => %{"id" => p[:uuid]},
        "publish_at" => "#{Date.utc_today() |> Date.add(10)}T09:30"
      })

    {:ok, _} = Posts.trash_post(ts["slug"], p[:uuid])
    assert Danger.restore_posts(%{"posts" => [%{"id" => p[:uuid]}]}, ctx())

    assert {:preview,
            %{
              "rows" => [
                %{"becomes_visible" => false, "changes" => %{"status" => %{"to" => "scheduled"}}}
              ]
            }, _} = restore([%{"id" => p[:uuid]}], %{dry_run?: true})
  end
end
