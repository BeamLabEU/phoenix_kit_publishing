defmodule PhoenixKit.Modules.Publishing.API.TrashPostsTest do
  use PhoenixKit.DataCase, async: false

  import PhoenixKitPublishing.ActivityLogAssertions

  alias PhoenixKit.Modules.Publishing.{DBStorage, Groups}
  alias PhoenixKitPublishing.Test.ApiCase
  alias PhoenixKitPublishing.Test.ApiFixtures, as: Fx

  setup do
    Fx.languages!()
    g = Fx.group!()
    draft = Fx.post!(g["slug"], %{title: "Draft", slug: "draft"})
    live = Fx.post!(g["slug"], %{title: "Live", slug: "live"})
    Fx.body!(g["slug"], live[:uuid], "# Live")
    Fx.publish!(g["slug"], live[:uuid])
    %{g: g, draft: draft, live: live}
  end

  defp trash(refs, overrides \\ %{}),
    do: ApiCase.call("publishing.trash_posts", %{"posts" => refs}, overrides)

  defp slug_ref(ctx, slug), do: %{"group" => ctx.g["slug"], "slug" => slug}

  test "trashes a draft and a live post; the live pointer is kept and the public post stops resolving",
       ctx do
    assert {:ok, %{"summary" => %{"removed" => 2}}} = trash([Fx.ref(ctx.draft), Fx.ref(ctx.live)])
    assert Fx.db_post(ctx.draft[:uuid]).trashed_at != nil
    live = Fx.db_post(ctx.live[:uuid])
    assert live.trashed_at != nil and live.active_version_uuid != nil
    assert DBStorage.get_post(ctx.g["slug"], "live") == nil
    row = assert_activity_logged("publishing.post.trashed", resource_uuid: ctx.live[:uuid])
    assert row.mode == "auto" and row.metadata["via"] == "api"
    assert row.metadata["tool"] == "publishing.trash_posts"
  end

  test "a second call with SLUG refs answers unchanged, not not_found, and logs nothing", ctx do
    {:ok, _} = trash([slug_ref(ctx, "draft")])
    n = length(list_activities())

    assert {:ok, %{"results" => [%{"action" => "unchanged"}], "summary" => %{"unchanged" => 1}}} =
             trash([slug_ref(ctx, "draft")])

    assert length(list_activities()) == n
  end

  test "the same post twice is a row error for the second occurrence and the first still succeeds",
       ctx do
    assert {:ok,
            %{
              "results" => [
                %{"action" => "removed"},
                %{"action" => "error", "error" => %{"code" => "invalid_ref"}}
              ]
            }} = trash([Fx.ref(ctx.draft), slug_ref(ctx, "draft")])
  end

  test "one bad row does not stop the others", ctx do
    assert {:ok,
            %{
              "results" => [
                %{"error" => %{"code" => "invalid_ref"}},
                %{"error" => %{"code" => "not_found"}},
                %{"action" => "removed"}
              ]
            }} = trash([%{}, %{"id" => Ecto.UUID.generate()}, Fx.ref(ctx.draft)])
  end

  test "more than 50 refs are refused by max_items", ctx do
    refs = for _ <- 1..51, do: Fx.ref(ctx.draft)
    assert {:error, :validation_failed, _, _} = trash(refs)
  end

  test "a post in a trashed group is a group_trashed row", ctx do
    {:ok, _} = Groups.trash_group(ctx.g["slug"])

    assert {:ok, %{"results" => [%{"error" => %{"code" => "group_trashed"}}]}} =
             trash([Fx.ref(ctx.draft)])
  end

  test "the preview: status change, title, languages, paths of a live post; ALL tables unchanged; fingerprint follows an edit",
       ctx do
    before = Fx.table_state()

    assert {:preview, %{"requires_confirmation" => true, "rows" => [draft, live]}, f1} =
             trash([Fx.ref(ctx.draft), Fx.ref(ctx.live)], %{dry_run?: true})

    assert Fx.table_state() == before
    assert draft["changes"]["status"] == %{"from" => "draft", "to" => "trashed"}
    assert draft["public_paths"] == []
    assert live["changes"]["status"]["from"] == "published"
    assert live["title"] == "Live" and live["languages"] == ["en-US"]
    assert Enum.any?(live["public_paths"], &String.contains?(&1, "live"))

    Fx.body!(ctx.g["slug"], ctx.live[:uuid], "edited", 1)

    assert {:preview, _, f2} =
             trash([Fx.ref(ctx.draft), Fx.ref(ctx.live)], %{dry_run?: true})

    assert f1 != f2
  end

  test "list_posts with status trashed lists them with titles", ctx do
    {:ok, _} = trash([Fx.ref(ctx.live)])

    assert {:ok, %{"posts" => [%{"title" => "Live", "status" => "trashed"}]}} =
             ApiCase.call("publishing.list_posts", %{
               "group" => ctx.g["slug"],
               "status" => "trashed"
             })
  end

  test "the preview lists no public paths for a post that is scheduled ahead: nothing resolves yet" do
    ts = Fx.group!(mode: "timestamp")
    p = Fx.post!(ts["slug"], %{title: "Soon"})
    Fx.body!(ts["slug"], p[:uuid], "x")

    {:ok, _} =
      ApiCase.call("publishing.schedule_post", %{
        "post" => %{"id" => p[:uuid]},
        "publish_at" => "#{Date.utc_today() |> Date.add(10)}T09:30"
      })

    assert {:preview, %{"rows" => [row]}, _} = trash([%{"id" => p[:uuid]}], %{dry_run?: true})
    assert row["changes"]["status"] == %{"from" => "scheduled", "to" => "trashed"}
    assert row["public_paths"] == []
  end
end
