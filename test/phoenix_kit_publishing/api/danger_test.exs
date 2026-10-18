defmodule PhoenixKit.Modules.Publishing.API.DangerTest do
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Modules.Publishing.API.Danger
  alias PhoenixKit.Modules.Publishing.{Posts, Versions}
  alias PhoenixKitPublishing.Test.ApiCase
  alias PhoenixKitPublishing.Test.ApiFixtures, as: Fx
  alias PhoenixKitPublishing.Test.Repo, as: TestRepo

  defp ctx, do: ApiCase.ctx(%{dry_run?: true})

  setup do
    Fx.languages!()
    g = Fx.group!()
    post = Fx.post!(g["slug"], %{title: "T", slug: "t"})
    %{g: g, post: post, ref: %{"id" => post[:uuid]}}
  end

  describe "update_post" do
    test "a draft edit of an unpublished post is not dangerous", %{ref: ref} do
      refute Danger.update_post(%{"post" => ref, "title" => "x"}, ctx())
    end

    test "the active version is dangerous; a draft beside a live version is not; an archived one is",
         %{g: g, post: post, ref: ref} do
      Fx.publish!(g["slug"], post[:uuid], 1)
      assert Danger.update_post(%{"post" => ref, "version" => 1, "title" => "x"}, ctx())
      {:ok, _} = Versions.create_new_version(g["slug"], post, %{}, %{})

      refute Danger.update_post(%{"post" => ref, "title" => "x"}, ctx()),
             "the highest draft is v2"

      Fx.publish!(g["slug"], post[:uuid], 2)

      assert Danger.update_post(%{"post" => ref, "version" => 1, "title" => "x"}, ctx()),
             "v1 is archived and the post has a live version"
    end

    test "an archived version of an UNPUBLISHED post is not dangerous", %{
      g: g,
      post: post,
      ref: ref
    } do
      Fx.publish!(g["slug"], post[:uuid], 1)
      :ok = Versions.unpublish_post(g["slug"], post[:uuid], target_status: "archived")
      refute Danger.update_post(%{"post" => ref, "version" => 1, "title" => "x"}, ctx())
    end

    test "a slug rename of a post with a live version is dangerous even when a draft is written",
         %{g: g, post: post, ref: ref} do
      Fx.publish!(g["slug"], post[:uuid], 1)
      {:ok, _} = Versions.create_new_version(g["slug"], post, %{}, %{})
      assert Danger.update_post(%{"post" => ref, "slug" => "renamed", "title" => "x"}, ctx())

      refute Danger.update_post(%{"post" => ref, "slug" => "t", "title" => "x"}, ctx()),
             "the same slug is no rename"
    end

    test "fail closed: unresolvable refs, missing versions, bad ids answer true", %{ref: ref} do
      assert Danger.update_post(%{"post" => %{"id" => Ecto.UUID.generate()}}, ctx())
      assert Danger.update_post(%{"post" => %{"id" => "nope"}}, ctx())
      assert Danger.update_post(%{"post" => %{}}, ctx())
      assert Danger.update_post(%{"post" => ref, "version" => 99, "title" => "x"}, ctx())
      assert Danger.update_post(%{}, ctx())
    end

    test "a database error answers true (never 'safe')", %{ref: ref} do
      TestRepo.query!(
        "ALTER TABLE phoenix_kit_publishing_versions RENAME TO phoenix_kit_publishing_versions_x"
      )

      assert Danger.update_post(%{"post" => ref, "title" => "x"}, ctx())
    end

    test "a trashed post is not dangerous by the live clause (the handler refuses it)", %{
      g: g,
      post: post,
      ref: ref
    } do
      Fx.publish!(g["slug"], post[:uuid], 1)
      {:ok, _} = Posts.trash_post(g["slug"], post[:uuid])
      refute Danger.update_post(%{"post" => ref, "version" => 1, "title" => "x"}, ctx())
    end
  end

  describe "live_condition/3 (the pure recheck of the :locked_check closure)" do
    test "from the two fresh rows only" do
      live = %{active_version_uuid: "a", slug: "s"}
      assert Danger.live_condition(live, %{uuid: "a", status: "published"}, nil)
      assert Danger.live_condition(live, %{uuid: "b", status: "archived"}, nil)
      refute Danger.live_condition(live, %{uuid: "b", status: "draft"}, nil)

      refute Danger.live_condition(
               %{active_version_uuid: nil, slug: "s"},
               %{uuid: "b", status: "archived"},
               nil
             )

      assert Danger.live_condition(live, %{uuid: "b", status: "draft"}, "other")
      refute Danger.live_condition(live, %{uuid: "b", status: "draft"}, "s")
    end
  end
end
