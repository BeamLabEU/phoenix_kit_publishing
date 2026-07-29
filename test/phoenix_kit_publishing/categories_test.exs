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

  describe "reorder_categories/3" do
    test "renumbers within each sibling group from the flattened DOM order", %{slug: slug} do
      {:ok, a} = Categories.create_category(slug, %{"name" => "A", "position" => 0})
      {:ok, b} = Categories.create_category(slug, %{"name" => "B", "position" => 1})
      {:ok, c1} = Categories.create_category(slug, %{"name" => "C1", "parent_uuid" => a.uuid})
      {:ok, c2} = Categories.create_category(slug, %{"name" => "C2", "parent_uuid" => a.uuid})

      # B before A at the root; children swapped within A.
      {:ok, changed} =
        Categories.reorder_categories(slug, [b.uuid, c2.uuid, c1.uuid, a.uuid])

      assert changed > 0

      assert [{%{name: "B"}, 0}, {%{name: "A"}, 0}, {%{name: "C2"}, 1}, {%{name: "C1"}, 1}] =
               Categories.list_tree(slug)
    end

    test "a cross-parent drop position cannot re-parent", %{slug: slug} do
      {:ok, a} = Categories.create_category(slug, %{"name" => "A"})
      {:ok, child} = Categories.create_category(slug, %{"name" => "Kid", "parent_uuid" => a.uuid})

      {:ok, _} = Categories.reorder_categories(slug, [child.uuid, a.uuid])

      {:ok, reloaded} = Categories.get_category(child.uuid)
      assert reloaded.parent_uuid == a.uuid
    end

    test "unknown and foreign uuids are ignored", %{slug: slug} do
      {:ok, other_group} = Groups.add_group(unique_name(), mode: "slug")
      {:ok, foreign} = Categories.create_category(other_group["slug"], %{"name" => "Foreign"})
      {:ok, a} = Categories.create_category(slug, %{"name" => "A"})

      {:ok, _} =
        Categories.reorder_categories(slug, [
          Ecto.UUID.generate(),
          foreign.uuid,
          a.uuid,
          "not-a-uuid"
        ])

      {:ok, foreign_reloaded} = Categories.get_category(foreign.uuid)
      assert foreign_reloaded.position == 0
    end

    test "rejects a non-list or oversized payload", %{slug: slug} do
      assert {:error, :invalid_order} = Categories.reorder_categories(slug, "bogus")

      too_many = Enum.map(1..501, fn _ -> Ecto.UUID.generate() end)
      assert {:error, :invalid_order} = Categories.reorder_categories(slug, too_many)
    end

    test "a partial (stale) payload still renumbers the full sibling group", %{slug: slug} do
      {:ok, a} = Categories.create_category(slug, %{"name" => "A", "position" => 0})
      {:ok, b} = Categories.create_category(slug, %{"name" => "B", "position" => 1})
      {:ok, c} = Categories.create_category(slug, %{"name" => "C", "position" => 2})

      # A stale client that never saw C sends only [B, A]: sent rows lead,
      # unsent siblings follow — no position collisions.
      {:ok, _} = Categories.reorder_categories(slug, [b.uuid, a.uuid])

      positions =
        Map.new(Categories.list_categories(slug), fn cat -> {cat.uuid, cat.position} end)

      assert positions == %{b.uuid => 0, a.uuid => 1, c.uuid => 2}
    end
  end

  describe "move_category/3" do
    test "appends the moved category at the end of the new sibling group", %{slug: slug} do
      {:ok, parent} = Categories.create_category(slug, %{"name" => "Parent"})

      {:ok, first} =
        Categories.create_category(slug, %{
          "name" => "First",
          "parent_uuid" => parent.uuid,
          "position" => 5
        })

      {:ok, mover} = Categories.create_category(slug, %{"name" => "Mover", "position" => 0})

      {:ok, moved} = Categories.move_category(mover.uuid, parent.uuid)
      assert moved.parent_uuid == parent.uuid
      assert moved.position == 6

      assert [{%{name: "Parent"}, 0}, {%{name: "First"}, 1}, {%{name: "Mover"}, 1}] =
               Categories.list_tree(slug)

      # Moving to the root appends after the root's max position too.
      {:ok, rooted} = Categories.move_category(first.uuid, "")
      assert rooted.parent_uuid == nil
      assert rooted.position == parent.position + 1
    end

    test "keeps the cycle guard", %{slug: slug} do
      {:ok, a} = Categories.create_category(slug, %{"name" => "A"})
      {:ok, b} = Categories.create_category(slug, %{"name" => "B", "parent_uuid" => a.uuid})

      assert {:error, :category_cycle} = Categories.move_category(a.uuid, b.uuid)
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
