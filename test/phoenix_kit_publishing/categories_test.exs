defmodule PhoenixKit.Modules.Publishing.CategoriesTest do
  @moduledoc """
  Context tests for the WordPress-parity category taxonomy (core V159):
  CRUD + slug rules, tree ordering, cycle/scope guards, and post
  assignments.
  """

  use PhoenixKitPublishing.DataCase, async: false

  alias PhoenixKit.Modules.Publishing.Categories
  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.Posts
  alias PhoenixKit.Modules.Publishing.Versions

  defp unique_name, do: "cat-#{System.unique_integer([:positive])}"

  setup do
    {:ok, group} = Groups.add_group(unique_name(), mode: "slug")
    %{group: group, slug: group["slug"]}
  end

  describe "create_category/3" do
    test "derives the slug from the name when absent", %{slug: slug} do
      {:ok, cat} = Categories.create_category(slug, %{"name" => "Hello World"})
      assert cat.slug == "hello-world"
      assert cat.name == "Hello World"
    end

    test "rejects a duplicate slug within the group but allows it across groups", %{slug: slug} do
      {:ok, _} = Categories.create_category(slug, %{"name" => "News"})

      assert {:error, %Ecto.Changeset{valid?: false}} =
               Categories.create_category(slug, %{"name" => "News"})

      {:ok, other} = Groups.add_group(unique_name(), mode: "slug")
      assert {:ok, _} = Categories.create_category(other["slug"], %{"name" => "News"})
    end

    test "rejects a parent from another group", %{slug: slug} do
      {:ok, other} = Groups.add_group(unique_name(), mode: "slug")
      {:ok, foreign} = Categories.create_category(other["slug"], %{"name" => "Foreign"})

      assert {:error, :parent_wrong_group} =
               Categories.create_category(slug, %{
                 "name" => "Child",
                 "parent_uuid" => foreign.uuid
               })
    end

    test "unknown group errors", %{} do
      assert {:error, :group_not_found} =
               Categories.create_category("no-such-group", %{"name" => "X"})
    end
  end

  describe "tree + updates" do
    test "list_tree orders parents before children with depths", %{slug: slug} do
      {:ok, root_b} = Categories.create_category(slug, %{"name" => "Bravo", "position" => 2})
      {:ok, root_a} = Categories.create_category(slug, %{"name" => "Alpha", "position" => 1})

      {:ok, child} =
        Categories.create_category(slug, %{"name" => "Alpha Child", "parent_uuid" => root_a.uuid})

      tree = Categories.list_tree(slug)
      assert [{^root_a, 0}, {^child, 1}, {^root_b, 0}] = tree
    end

    test "re-parenting onto a descendant is rejected", %{slug: slug} do
      {:ok, a} = Categories.create_category(slug, %{"name" => "A"})
      {:ok, b} = Categories.create_category(slug, %{"name" => "B", "parent_uuid" => a.uuid})
      {:ok, c} = Categories.create_category(slug, %{"name" => "C", "parent_uuid" => b.uuid})

      assert {:error, :category_cycle} =
               Categories.update_category(a.uuid, %{"parent_uuid" => c.uuid})

      assert {:error, :category_cycle} =
               Categories.update_category(a.uuid, %{"parent_uuid" => a.uuid})
    end

    test "deleting a parent lifts children to the root", %{slug: slug} do
      {:ok, a} = Categories.create_category(slug, %{"name" => "A"})
      {:ok, b} = Categories.create_category(slug, %{"name" => "B", "parent_uuid" => a.uuid})

      {:ok, _} = Categories.delete_category(a.uuid)

      {:ok, reloaded} = Categories.get_category(b.uuid)
      assert reloaded.parent_uuid == nil
    end
  end

  describe "post assignments" do
    setup %{slug: slug} do
      {:ok, post} =
        Posts.create_post(slug, %{title: "Post", slug: "cat-post", content: "Body."})

      :ok = Versions.publish_version(slug, post.uuid, 1)
      %{post: post}
    end

    test "replace_post_categories drops foreign-group uuids", %{slug: slug, post: post} do
      {:ok, mine} = Categories.create_category(slug, %{"name" => "Mine"})
      {:ok, other} = Groups.add_group(unique_name(), mode: "slug")
      {:ok, foreign} = Categories.create_category(other["slug"], %{"name" => "Foreign"})

      {:ok, applied} =
        Categories.replace_post_categories(post.uuid, [mine.uuid, foreign.uuid, "not-a-uuid"])

      assert applied == [mine.uuid]
      assert Categories.category_uuids_for_post(post.uuid) == [mine.uuid]
    end

    test "replacing with [] clears the set", %{slug: slug, post: post} do
      {:ok, cat} = Categories.create_category(slug, %{"name" => "C"})
      {:ok, _} = Categories.replace_post_categories(post.uuid, [cat.uuid])
      {:ok, _} = Categories.replace_post_categories(post.uuid, [])
      assert Categories.category_uuids_for_post(post.uuid) == []
    end

    test "published_post_counts counts published posts only", %{slug: slug, post: post} do
      {:ok, cat} = Categories.create_category(slug, %{"name" => "Counted"})
      {:ok, _} = Categories.replace_post_categories(post.uuid, [cat.uuid])

      {:ok, draft} =
        Posts.create_post(slug, %{title: "Draft", slug: "cat-draft", content: "x"})

      {:ok, _} = Categories.replace_post_categories(draft.uuid, [cat.uuid])

      assert Categories.published_post_counts(slug) == %{cat.uuid => 1}
    end

    test "deleting a category cascades its assignments", %{slug: slug, post: post} do
      {:ok, cat} = Categories.create_category(slug, %{"name" => "Gone"})
      {:ok, _} = Categories.replace_post_categories(post.uuid, [cat.uuid])
      {:ok, _} = Categories.delete_category(cat.uuid)
      assert Categories.category_uuids_for_post(post.uuid) == []
    end
  end
end
