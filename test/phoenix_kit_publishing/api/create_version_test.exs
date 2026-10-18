defmodule PhoenixKit.Modules.Publishing.API.CreateVersionTest do
  use PhoenixKit.DataCase, async: false

  import PhoenixKitPublishing.ActivityLogAssertions

  alias PhoenixKit.Modules.Publishing.{Groups, Posts}
  alias PhoenixKitPublishing.Test.ApiCase
  alias PhoenixKitPublishing.Test.ApiFixtures, as: Fx

  setup do
    Fx.languages!()
    g = Fx.group!()
    post = Fx.post!(g["slug"], %{title: "Source", slug: "source"})
    Fx.body!(g["slug"], post[:uuid], "source body")
    Fx.translation!(g["slug"], post[:uuid], "de-DE", "Quelle", "Quelltext")
    %{g: g, post: post}
  end

  defp create_version(ctx, extra \\ %{}, overrides \\ %{}),
    do:
      ApiCase.call(
        "publishing.create_version",
        Map.merge(%{"post" => Fx.ref(ctx.post)}, extra),
        overrides
      )

  test "the default is a draft copy of the latest version with every language", ctx do
    assert {:ok, %{"action" => "created", "version" => 2, "post" => post}} = create_version(ctx)
    assert post["latest_version"] == 2
    assert Fx.version(ctx.post[:uuid], 2).status == "draft"

    assert Fx.contents(ctx.post[:uuid], 2)
           |> Enum.map(&{&1.language, &1.title, &1.content})
           |> Enum.sort() ==
             [{"de-DE", "Quelle", "Quelltext"}, {"en-US", "Source", "source body"}]
  end

  test "the default copies the latest version, not the first", ctx do
    {:ok, _} = create_version(ctx)
    Fx.body!(ctx.g["slug"], ctx.post[:uuid], "v2 body", 2)

    assert {:ok, %{"version" => 3}} = create_version(ctx)
    assert Fx.content(ctx.post[:uuid], "en-US", 3).content == "v2 body"
    assert Fx.content(ctx.post[:uuid], "en-US", 1).content == "source body"
  end

  test "from_version copies that version", ctx do
    {:ok, _} = create_version(ctx)
    Fx.body!(ctx.g["slug"], ctx.post[:uuid], "v2 body", 2)
    assert {:ok, %{"version" => 3}} = create_version(ctx, %{"from_version" => 1})
    assert Fx.content(ctx.post[:uuid], "en-US", 3).content == "source body"
  end

  test "blank builds an empty primary-language draft and no other language", ctx do
    assert {:ok, %{"version" => 2}} = create_version(ctx, %{"blank" => true})
    assert [%{language: "en-US", title: "", content: ""}] = Fx.contents(ctx.post[:uuid], 2)
  end

  test "blank together with from_version, and a from_version that does not exist, are refused",
       ctx do
    assert {:error, :validation_failed, _, %{errors: [%{path: "blank"}]}} =
             create_version(ctx, %{"blank" => true, "from_version" => 1})

    assert {:error, :validation_failed, _, %{errors: [%{reason: "version_not_found"}]}} =
             create_version(ctx, %{"from_version" => 9})
  end

  test "a live post keeps its live pointer and its live version", ctx do
    Fx.publish!(ctx.g["slug"], ctx.post[:uuid])
    live = Fx.db_post(ctx.post[:uuid]).active_version_uuid
    assert {:ok, _} = create_version(ctx)
    assert Fx.db_post(ctx.post[:uuid]).active_version_uuid == live
    assert Fx.version(ctx.post[:uuid], 1).status == "published"
  end

  test "a trashed post and a trashed group are refused", ctx do
    {:ok, _} = Posts.trash_post(ctx.g["slug"], ctx.post[:uuid])

    assert {:error, :validation_failed, _, %{errors: [%{reason: "post_trashed"}]}} =
             create_version(ctx)

    g2 = Fx.group!()
    p2 = Fx.post!(g2["slug"], %{title: "T", slug: "t"})
    {:ok, _} = Groups.trash_group(g2["slug"])

    assert {:error, :validation_failed, _, %{errors: [%{reason: "group_trashed"}]}} =
             ApiCase.call("publishing.create_version", %{"post" => %{"id" => p2[:uuid]}})
  end

  test "the activity row is attributed", ctx do
    {:ok, _} = create_version(ctx)

    row =
      assert_activity_logged("publishing.version.created",
        metadata_has: %{"post_uuid" => ctx.post[:uuid]}
      )

    assert row.mode == "auto" and row.metadata["via"] == "api" and
             row.metadata["tool"] == "publishing.create_version"
  end

  test "a dry run writes nothing and previews the source", ctx do
    before = Fx.table_state()

    assert {:preview,
            %{
              "requires_confirmation" => false,
              "rows" => [%{"action" => "create_version", "source_version" => 1}]
            }, _} =
             create_version(ctx, %{}, %{dry_run?: true})

    assert Fx.table_state() == before
  end

  test "a dry run previews the latest version when there are several", ctx do
    {:ok, _} = create_version(ctx)
    before = Fx.table_state()

    assert {:preview, %{"rows" => [%{"source_version" => 2, "blank" => false}]}, _} =
             create_version(ctx, %{}, %{dry_run?: true})

    assert Fx.table_state() == before
  end

  test "a dry run of a blank version writes nothing", ctx do
    before = Fx.table_state()

    assert {:preview,
            %{
              "requires_confirmation" => false,
              "rows" => [
                %{"action" => "create_version", "source_version" => nil, "blank" => true}
              ]
            }, _} = create_version(ctx, %{"blank" => true}, %{dry_run?: true})

    assert Fx.table_state() == before
  end

  test "a dry run refuses a missing source version like the real call", ctx do
    before = Fx.table_state()

    assert {:error, :validation_failed, _, %{errors: [%{reason: "version_not_found"}]}} =
             create_version(ctx, %{"from_version" => 9}, %{dry_run?: true})

    assert Fx.table_state() == before
  end

  test "a dry run refuses a trashed post and a trashed group like the real call", ctx do
    g2 = Fx.group!()
    p2 = Fx.post!(g2["slug"], %{title: "T", slug: "t"})
    {:ok, _} = Posts.trash_post(g2["slug"], p2[:uuid])

    assert {:error, :validation_failed, _, %{errors: [%{reason: "post_trashed"}]}} =
             ApiCase.call("publishing.create_version", %{"post" => %{"id" => p2[:uuid]}}, %{
               dry_run?: true
             })

    g3 = Fx.group!()
    p3 = Fx.post!(g3["slug"], %{title: "T", slug: "t"})
    {:ok, _} = Groups.trash_group(g3["slug"])

    assert {:error, :validation_failed, _, %{errors: [%{reason: "group_trashed"}]}} =
             ApiCase.call("publishing.create_version", %{"post" => %{"id" => p3[:uuid]}}, %{
               dry_run?: true
             })
  end

  test "the tool has no danger" do
    assert ApiCase.tool!("publishing.create_version").danger == nil
  end
end
