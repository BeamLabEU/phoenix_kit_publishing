defmodule PhoenixKit.Modules.Publishing.API.DeleteCategoriesTest do
  use PhoenixKit.DataCase, async: false

  import PhoenixKitPublishing.ActivityLogAssertions

  alias PhoenixKit.Modules.Publishing.API.Common
  alias PhoenixKit.Modules.Publishing.{Categories, Groups, Posts}
  alias PhoenixKitPublishing.Test.ApiCase
  alias PhoenixKitPublishing.Test.ApiFixtures, as: Fx
  alias PhoenixKitPublishing.Test.Repo, as: TestRepo

  setup do
    Fx.languages!()
    g = Fx.group!()
    cat = Fx.category!(g["slug"], "Doomed", %{slug: "doomed"})
    other = Fx.category!(g["slug"], "Other", %{slug: "other"})
    %{g: g, cat: cat, other: other}
  end

  defp delete(g, refs, overrides \\ %{}),
    do:
      ApiCase.call(
        "publishing.delete_categories",
        %{"group" => g["slug"], "refs" => refs},
        overrides
      )

  defp file_post(g, title, slug, uuids, publish?) do
    post = Fx.post!(g["slug"], %{title: title, slug: slug})
    Fx.body!(g["slug"], post[:uuid], "body")
    {:ok, p} = Posts.read_post_by_uuid(post[:uuid])
    {:ok, _} = Posts.update_post(g["slug"], p, %{"category_uuids" => uuids}, publish: false)
    if publish?, do: Fx.publish!(g["slug"], post[:uuid])
    post
  end

  defp post_category_rows(category_uuid) do
    TestRepo.query!(
      "SELECT count(*) FROM phoenix_kit_publishing_post_categories WHERE category_uuid = $1",
      [Ecto.UUID.dump!(category_uuid)]
    ).rows
    |> hd()
    |> hd()
  end

  test "deletes the category; the posts survive and only their filing is removed, draft and live versions alike",
       %{g: g, cat: cat, other: other} do
    live = file_post(g, "Live", "live", [cat.uuid, other.uuid], true)
    draft = file_post(g, "Draft", "draft", [cat.uuid], false)

    assert {:ok, %{"results" => [%{"action" => "removed", "id" => id}]}} =
             delete(g, [%{"id" => cat.uuid}])

    assert id == cat.uuid
    assert {:error, :not_found} = Categories.fetch_category(cat.uuid)
    assert Fx.version(live[:uuid]).data["category_uuids"] == [other.uuid]
    assert Fx.version(draft[:uuid]).data["category_uuids"] == []
    assert Fx.db_post(live[:uuid]) != nil and Fx.db_post(draft[:uuid]) != nil
    assert Common.published_post_counts!(g["slug"]) == %{other.uuid => 1}
    assert post_category_rows(cat.uuid) == 0
    row = assert_activity_logged("publishing.category.deleted", resource_uuid: cat.uuid)
    assert row.mode == "auto" and row.metadata["via"] == "api"
  end

  test "children move to the top level", %{g: g, cat: cat} do
    kid = Fx.category!(g["slug"], "Kid", %{slug: "kid", parent_uuid: cat.uuid})
    {:ok, _} = delete(g, [%{"slug" => "doomed"}])
    assert Enum.find(Common.categories!(g["slug"]), &(&1.uuid == kid.uuid)).parent_uuid == nil
  end

  test "the preview counts children, published posts, filed versions (a draft filing too) and post_categories; ALL tables unchanged",
       %{g: g, cat: cat} do
    Fx.category!(g["slug"], "Kid", %{slug: "kid", parent_uuid: cat.uuid})
    file_post(g, "Live", "live", [cat.uuid], true)
    file_post(g, "Draft", "draft", [cat.uuid], false)
    before = Fx.table_state()
    cascade_before = post_category_rows(cat.uuid)

    assert {:preview, %{"requires_confirmation" => true, "rows" => [row]}, f1} =
             delete(g, [%{"id" => cat.uuid}], %{dry_run?: true})

    assert Fx.table_state() == before
    assert post_category_rows(cat.uuid) == cascade_before

    assert %{
             "irreversible" => true,
             "children" => 1,
             "published_posts" => 1,
             "filed_versions" => 2,
             "post_categories" => pc
           } = row

    assert is_integer(pc)

    file_post(g, "Late", "late", [cat.uuid], false)
    assert {:preview, _, f2} = delete(g, [%{"id" => cat.uuid}], %{dry_run?: true})
    assert f1 != f2
  end

  test "the fingerprint follows the children that would move to the top level", %{g: g, cat: cat} do
    preview = fn ->
      assert {:preview, %{"rows" => [row]}, fingerprint} =
               delete(g, [%{"id" => cat.uuid}], %{dry_run?: true})

      {row["children"], fingerprint}
    end

    {0, none} = preview.()
    assert {0, ^none} = preview.()

    kid = Fx.category!(g["slug"], "Kid", %{slug: "kid", parent_uuid: cat.uuid})
    {1, one} = preview.()
    refute one == none

    # another child instead of the first: the count is the same, the tree is not
    {:ok, _} = Categories.delete_category(kid.uuid)
    Fx.category!(g["slug"], "Other kid", %{slug: "other-kid", parent_uuid: cat.uuid})
    {1, swapped} = preview.()
    refute swapped == one
  end

  test "a second call is a not_found row; the same category twice and a malformed ref are row errors",
       %{g: g, cat: cat, other: other} do
    {:ok, _} = delete(g, [%{"id" => cat.uuid}])

    assert {:ok, %{"results" => [%{"error" => %{"code" => "not_found"}}]}} =
             delete(g, [%{"id" => cat.uuid}])

    assert {:ok,
            %{"results" => [%{"action" => "removed"}, %{"error" => %{"code" => "invalid_ref"}}]}} =
             delete(g, [%{"slug" => "other"}, %{"id" => other.uuid}])

    assert {:ok, %{"results" => [%{"error" => %{"code" => "invalid_ref"}}]}} =
             delete(g, [%{"id" => "x", "slug" => "y"}])
  end

  test "a category of another group is not_found and 101 refs are refused", %{g: g} do
    foreign = Fx.category!(Fx.group!()["slug"], "Foreign")

    assert {:ok, %{"results" => [%{"error" => %{"code" => "not_found"}}]}} =
             delete(g, [%{"id" => foreign.uuid}])

    assert {:ok, _} = Categories.fetch_category(foreign.uuid)

    assert {:error, :validation_failed, _, _} =
             delete(g, for(_ <- 1..101, do: %{"slug" => "doomed"}))
  end

  test "an unfiling that did not complete is a unfile_incomplete warning on the row, not an error",
       %{g: g, cat: cat} do
    post = file_post(g, "Filed", "filed", [cat.uuid], false)
    flag = make_ref()
    me = self()
    handler = "unfile-#{System.unique_integer([:positive])}"

    # Right after the module's unfiling UPDATE of the versions, put the uuid back (simulates a strip that failed).
    :telemetry.attach(
      handler,
      TestRepo.config()[:telemetry_prefix] ++ [:query],
      fn _e, _m, meta, _c ->
        if self() == me and meta.source == "phoenix_kit_publishing_versions" and
             meta.query =~ ~r/^UPDATE/ and Process.get(flag) == nil do
          Process.put(flag, true)

          TestRepo.query!(
            "UPDATE phoenix_kit_publishing_versions SET data = jsonb_set(data, '{category_uuids}', $1::jsonb) WHERE post_uuid = $2",
            [[cat.uuid], Ecto.UUID.dump!(post[:uuid])]
          )
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert {:ok,
            %{
              "results" => [
                %{
                  "action" => "removed",
                  "warnings" => [%{"code" => "unfile_incomplete", "count" => 1}]
                }
              ]
            }} = delete(g, [%{"id" => cat.uuid}])

    assert Process.get(flag) == true
  end

  test "a trashed group is refused; an unknown group is not_found", %{g: g} do
    assert {:error, :not_found, _, _} =
             ApiCase.call("publishing.delete_categories", %{
               "group" => "nope",
               "refs" => [%{"slug" => "x"}]
             })

    {:ok, _} = Groups.trash_group(g["slug"])

    assert {:error, :validation_failed, _, %{errors: [%{reason: "group_trashed"}]}} =
             delete(g, [%{"slug" => "doomed"}])
  end

  test "the declaration says what it does" do
    tool = ApiCase.tool!("publishing.delete_categories")
    assert tool.description =~ "Permanently" and tool.description =~ "no undo"
    assert String.starts_with?(tool.description, "Permanently deletes categories.")

    assert tool.danger == :always and tool.scope == "publishing.categories:delete" and
             tool.annotations[:destructive] == true and tool.max_items == 100
  end
end
