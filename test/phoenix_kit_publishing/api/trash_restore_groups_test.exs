defmodule PhoenixKit.Modules.Publishing.API.TrashRestoreGroupsTest do
  use PhoenixKit.DataCase, async: false

  import PhoenixKitPublishing.ActivityLogAssertions

  alias PhoenixKit.Modules.Publishing.API.Common
  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKitPublishing.Test.ApiCase
  alias PhoenixKitPublishing.Test.ApiFixtures, as: Fx

  setup do
    Fx.languages!()
    g = Fx.group!(name: "Trash Me")
    live = Fx.post!(g["slug"], %{title: "Live", slug: "live"})
    Fx.body!(g["slug"], live[:uuid], "x")
    Fx.publish!(g["slug"], live[:uuid])
    Fx.post!(g["slug"], %{title: "Draft", slug: "draft"})
    %{g: g, live: live}
  end

  defp trash(slugs, overrides \\ %{}),
    do:
      ApiCase.call(
        "publishing.trash_groups",
        %{"groups" => Enum.map(slugs, &%{"slug" => &1})},
        overrides
      )

  defp restore(slugs, overrides \\ %{}),
    do:
      ApiCase.call(
        "publishing.restore_groups",
        %{"groups" => Enum.map(slugs, &%{"slug" => &1})},
        overrides
      )

  defp slugs(status),
    do:
      "publishing.list_groups"
      |> ApiCase.call(%{"status" => status})
      |> elem(1)
      |> Map.fetch!("groups")
      |> Enum.map(& &1["slug"])

  test "trash hides the group, its posts keep their state, writes into it are refused; restore brings it back",
       %{g: g, live: live} do
    assert {:ok, %{"summary" => %{"removed" => 1}}} = trash([g["slug"]])
    row = assert_activity_logged("publishing.group.trashed", resource_uuid: g["uuid"])
    assert row.mode == "auto" and row.metadata["via"] == "api"
    refute g["slug"] in slugs("active")
    assert g["slug"] in slugs("trashed")

    assert {:ok, %{"status" => "published"}} =
             ApiCase.call("publishing.get_post", %{"post" => Fx.ref(live)})

    assert {:error, :validation_failed, _, %{errors: [%{reason: "group_trashed"}]}} =
             ApiCase.call("publishing.create_post", %{"group" => g["slug"], "title" => "x"})

    assert {:ok, %{"summary" => %{"restored" => 1}}} = restore([g["slug"]])
    assert g["slug"] in slugs("active")

    assert {:ok, %{"action" => "created"}} =
             ApiCase.call("publishing.create_post", %{"group" => g["slug"], "title" => "x"})
  end

  test "a second trash and a restore of an active group are unchanged", %{g: g} do
    {:ok, _} = trash([g["slug"]])
    assert {:ok, %{"results" => [%{"action" => "unchanged"}]}} = trash([g["slug"]])
    {:ok, _} = restore([g["slug"]])
    assert {:ok, %{"results" => [%{"action" => "unchanged"}]}} = restore([g["slug"]])
  end

  # idx_publishing_groups_slug is unique over ALL statuses, so a trashed group and an active one
  # can never hold the same slug and the module's own :slug_taken answer cannot be provoked
  # through the database; the handler maps whatever the module answers.
  test "a slug_taken answer of the module becomes a slug_taken row" do
    assert %{"action" => "error", "error" => %{"code" => "slug_taken"}} =
             Common.row_from_error(%{"slug" => "news"}, :slug_taken)
  end

  test "duplicates, malformed and unknown refs are rows; more than 20 are refused", %{g: g} do
    assert {:ok,
            %{"results" => [%{"action" => "removed"}, %{"error" => %{"code" => "invalid_ref"}}]}} =
             trash([g["slug"], g["slug"]])

    assert {:ok, %{"results" => [%{"error" => %{"code" => "not_found"}}]}} = trash(["nope"])

    assert {:ok, %{"results" => [%{"error" => %{"code" => "invalid_ref"}}]}} =
             ApiCase.call("publishing.trash_groups", %{"groups" => [%{}]})

    assert {:error, :validation_failed, _, _} = trash(for(n <- 1..21, do: "g#{n}"))
  end

  test "a slug with a NUL byte is a not_found row, in the preview and in the real run" do
    nul = ["a" <> <<0>> <> "b"]

    for tool <- [&trash/2, &restore/2] do
      assert {:preview, %{"rows" => [%{"error" => %{"code" => "not_found"}}]}, _} =
               tool.(nul, %{dry_run?: true})

      assert {:ok, %{"results" => [%{"error" => %{"code" => "not_found"}}]}} =
               tool.(nul, %{})
    end
  end

  test "previews list post_count and live_posts and leave ALL tables unchanged", %{g: g} do
    before = Fx.table_state()

    assert {:preview,
            %{
              "requires_confirmation" => true,
              "rows" => [%{"post_count" => 2, "live_posts" => 1}]
            }, _} = trash([g["slug"]], %{dry_run?: true})

    assert Fx.table_state() == before
    {:ok, _} = trash([g["slug"]])

    assert {:preview,
            %{
              "requires_confirmation" => true,
              "rows" => [%{"action" => "restored", "post_count" => 2, "live_posts" => 1}]
            }, _} = restore([g["slug"]], %{dry_run?: true})
  end

  test "the preview fingerprint is stable and binds the group state and the error rows", %{g: g} do
    dry = %{dry_run?: true}
    {:preview, _, first} = trash([g["slug"]], dry)
    assert {:preview, _, ^first} = trash([g["slug"]], dry)

    {:ok, _} = Groups.update_group(g["slug"], %{"show_breadcrumbs" => true})
    assert {:preview, _, changed} = trash([g["slug"]], dry)
    assert changed != first

    {:preview, _, missing} = trash(["late"], dry)
    {:ok, _} = Groups.add_group("Late", slug: "late", mode: "slug")
    assert {:preview, _, appeared} = trash(["late"], dry)
    assert appeared != missing
  end

  test "the restore fingerprint is stable and binds the group state and the error rows", %{g: g} do
    dry = %{dry_run?: true}
    {:ok, _} = trash([g["slug"]])
    {:preview, _, first} = restore([g["slug"]], dry)
    assert {:preview, _, ^first} = restore([g["slug"]], dry)

    {:ok, _} = Groups.update_group(g["slug"], %{"show_breadcrumbs" => true})
    assert {:preview, _, changed} = restore([g["slug"]], dry)
    assert changed != first

    {:preview, _, missing} = restore(["late"], dry)
    {:ok, _} = Groups.add_group("Late", slug: "late", mode: "slug")
    assert {:preview, _, appeared} = restore(["late"], dry)
    assert appeared != missing
  end

  test "both fingerprints bind the post counts the owner was shown", %{g: g} do
    dry = %{dry_run?: true}
    {:preview, _, trash_before} = trash([g["slug"]], dry)
    {:ok, _} = trash([g["slug"]])
    {:preview, _, restore_before} = restore([g["slug"]], dry)
    {:ok, _} = restore([g["slug"]])

    draft = Fx.post!(g["slug"], %{title: "Late draft", slug: "late-draft"})
    assert {:preview, _, trash_more} = trash([g["slug"]], dry)
    assert trash_more != trash_before

    Fx.body!(g["slug"], draft[:uuid], "y")
    Fx.publish!(g["slug"], draft[:uuid])
    {:ok, _} = trash([g["slug"]])
    assert {:preview, _, restore_more} = restore([g["slug"]], dry)
    assert restore_more != restore_before
  end

  test "both tools are always confirmed, in the groups:delete scope" do
    for name <- ["publishing.trash_groups", "publishing.restore_groups"] do
      tool = ApiCase.tool!(name)
      assert tool.danger == :always and tool.scope == "publishing.groups:delete"
      assert tool.max_items == 20
    end
  end
end
