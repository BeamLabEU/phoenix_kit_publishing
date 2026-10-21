defmodule PhoenixKit.Modules.Publishing.API.ListCategoriesTest do
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Modules.Publishing.Posts
  alias PhoenixKitPublishing.Test.ApiCase
  alias PhoenixKitPublishing.Test.ApiFixtures, as: Fx
  alias PhoenixKitPublishing.Test.Repo, as: TestRepo

  test "flat, in tree order, with depth, parent and published counts" do
    g = Fx.group!()
    parent = Fx.category!(g["slug"], "Parent")
    child = Fx.category!(g["slug"], "Child", %{parent_uuid: parent.uuid})
    post = Fx.post!(g["slug"], %{title: "P", slug: "p"})
    {:ok, p} = Posts.read_post_by_uuid(post[:uuid])

    {:ok, _} =
      Posts.update_post(g["slug"], p, %{"category_uuids" => [child.uuid]}, publish: false)

    Fx.publish!(g["slug"], post[:uuid])

    assert {:ok, %{"categories" => [a, b], "count" => 2}} =
             ApiCase.call("publishing.list_categories", %{"group" => g["slug"]})

    assert {a["id"], a["depth"], a["parent_id"], a["published_post_count"]} ==
             {parent.uuid, 0, nil, 0}

    assert {b["id"], b["depth"], b["parent_id"], b["published_post_count"]} ==
             {child.uuid, 1, parent.uuid, 1}

    assert Map.has_key?(a, "name_i18n") and Map.has_key?(a, "position") and
             Map.has_key?(a, "description")
  end

  test "an empty group and an unknown group" do
    g = Fx.group!()

    assert {:ok, %{"categories" => [], "count" => 0}} =
             ApiCase.call("publishing.list_categories", %{"group" => g["slug"]})

    assert {:error, :not_found, _, _} =
             ApiCase.call("publishing.list_categories", %{"group" => "nope"})
  end

  test "a database error is an error, never an empty tree" do
    g = Fx.group!()
    Fx.category!(g["slug"], "Real")

    TestRepo.query!(
      "ALTER TABLE phoenix_kit_publishing_categories RENAME TO phoenix_kit_publishing_categories_x"
    )

    assert_raise Postgrex.Error, fn ->
      ApiCase.call("publishing.list_categories", %{"group" => g["slug"]})
    end
  end
end
