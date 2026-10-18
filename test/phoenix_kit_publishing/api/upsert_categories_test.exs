defmodule PhoenixKit.Modules.Publishing.API.UpsertCategoriesTest do
  use PhoenixKit.DataCase, async: false

  import PhoenixKitPublishing.ActivityLogAssertions

  alias PhoenixKit.Modules.Publishing.API.{Common, Danger}
  alias PhoenixKit.Modules.Publishing.{Categories, Groups}
  alias PhoenixKitPublishing.Test.ApiCase
  alias PhoenixKitPublishing.Test.ApiFixtures, as: Fx
  alias PhoenixKitPublishing.Test.Repo, as: TestRepo

  defp ctx, do: ApiCase.ctx(%{dry_run?: true})

  setup do
    Fx.languages!()
    %{g: Fx.group!()}
  end

  defp upsert(g, rows, overrides \\ %{}),
    do:
      ApiCase.call(
        "publishing.upsert_categories",
        %{"group" => g["slug"], "categories" => rows},
        overrides
      )

  # What core hands the handler once the owner confirmed: updating an existing category is a
  # confirmed write.
  defp confirmed(g, rows), do: upsert(g, rows, %{confirmation_uuid: "c"})

  defp stored(g, slug), do: Enum.find(Common.categories!(g["slug"]), &(&1.slug == slug))
  defp actions(result), do: result |> elem(1) |> Map.fetch!("results") |> Enum.map(& &1["action"])

  test "creates by slug: stored with its name and position, attributed", %{g: g} do
    assert {:ok, %{"results" => [%{"action" => "created", "id" => id}]}} =
             upsert(g, [%{"slug" => "news", "name" => "News", "position" => 3}])

    c = stored(g, "news")
    assert c.uuid == id and c.name == "News" and c.position == 3
    row = assert_activity_logged("publishing.category.created", resource_uuid: id)
    assert row.mode == "auto" and row.metadata["via"] == "api"
  end

  test "updates by id and by slug; identical values, also the whole name_i18n map, are unchanged",
       %{g: g} do
    c = Fx.category!(g["slug"], "Old", %{slug: "old"})
    assert actions(confirmed(g, [%{"id" => c.uuid, "name" => "New"}])) == ["updated"]
    assert actions(confirmed(g, [%{"slug" => "old", "description" => "d"}])) == ["updated"]

    assert actions(confirmed(g, [%{"slug" => "old", "name" => "New", "description" => "d"}])) ==
             ["unchanged"]

    {:ok, _} = confirmed(g, [%{"slug" => "old", "name_i18n" => %{"de" => "Neu"}}])

    assert actions(confirmed(g, [%{"slug" => "old", "name_i18n" => %{"de" => "Neu"}}])) ==
             ["unchanged"]
  end

  test "an update without a confirmation is refused row by row and nothing is written", %{g: g} do
    Fx.category!(g["slug"], "Old", %{slug: "old"})

    assert {:ok, %{"results" => [%{"error" => %{"code" => "revision_mismatch"}}]}} =
             upsert(g, [%{"slug" => "old", "name" => "New"}])

    assert stored(g, "old").name == "Old"
  end

  test "name_i18n REPLACES the stored map", %{g: g} do
    {:ok, _} =
      upsert(g, [%{"slug" => "c", "name" => "C", "name_i18n" => %{"de" => "A", "fr" => "B"}}])

    {:ok, _} = confirmed(g, [%{"slug" => "c", "name_i18n" => %{"de" => "X"}}])
    assert stored(g, "c").name_i18n == %{"de" => "X"}
  end

  test "ref and field errors are rows: invalid_ref, not_found, missing name, bad slug shape, and the others still run",
       %{g: g} do
    a = Fx.category!(g["slug"], "A", %{slug: "a"})
    _b = Fx.category!(g["slug"], "B", %{slug: "b"})

    assert {:ok, %{"results" => rows}} =
             upsert(g, [
               %{"id" => a.uuid, "slug" => "b"},
               %{"id" => Ecto.UUID.generate(), "name" => "x"},
               %{"slug" => "fresh"},
               %{"slug" => "Bad Slug", "name" => "x"},
               %{"name" => "no ref"},
               %{"slug" => "ok", "name" => "Fine"}
             ])

    assert Enum.map(rows, &(&1["error"] && &1["error"]["code"])) ==
             ["invalid_ref", "not_found", "validation_failed", "invalid_slug", "invalid_ref", nil]

    assert List.last(rows)["action"] == "created"
  end

  test "text and number fields are checked before any write: a NUL byte, a blank name and a huge position are rows",
       %{g: g} do
    c = Fx.category!(g["slug"], "Old", %{slug: "old"})

    assert {:ok, %{"results" => rows}} =
             confirmed(g, [
               %{"slug" => "nul", "name" => "a\u0000b"},
               %{"slug" => "old", "description" => "x\u0000"},
               %{"id" => c.uuid, "name_i18n" => %{"de" => "a\u0000"}},
               %{"slug" => "big", "name" => "Big", "position" => 4_294_967_296},
               %{"slug" => "blank", "name" => "   "},
               %{"slug" => "ok", "name" => "Fine"}
             ])

    assert Enum.map(rows, &(&1["error"] && &1["error"]["code"])) ==
             List.duplicate("validation_failed", 5) ++ [nil]

    assert Enum.map(Common.categories!(g["slug"]), & &1.slug) |> Enum.sort() == ["ok", "old"]
    assert stored(g, "old").description == nil
  end

  test "rows are applied in order: a later row sees the writes of an earlier one", %{g: g} do
    Fx.category!(g["slug"], "Old", %{slug: "old"})

    assert actions(
             confirmed(g, [
               %{"slug" => "old", "name" => "Interim"},
               %{"slug" => "old", "name" => "Old"}
             ])
           ) == ["updated", "updated"]

    assert stored(g, "old").name == "Old"
  end

  test "a category created and then updated in one request needs no confirmation", %{g: g} do
    assert {:ok,
            %{
              "results" => [
                %{"action" => "created", "id" => id},
                %{"action" => "updated", "id" => id}
              ]
            }} =
             upsert(g, [
               %{"slug" => "n", "name" => "N"},
               %{"slug" => "n", "description" => "d"}
             ])

    assert stored(g, "n").description == "d"
  end

  test "parents: by slug, by id, to the root with null; unknown, foreign and cyclic parents are rows",
       %{g: g} do
    root = Fx.category!(g["slug"], "Root", %{slug: "root"})
    foreign = Fx.category!(Fx.group!()["slug"], "Foreign")

    assert actions(
             upsert(g, [%{"slug" => "kid", "name" => "Kid", "parent" => %{"slug" => "root"}}])
           ) == ["created"]

    assert stored(g, "kid").parent_uuid == root.uuid
    assert actions(confirmed(g, [%{"slug" => "kid", "parent" => nil}])) == ["updated"]
    assert stored(g, "kid").parent_uuid == nil

    assert actions(confirmed(g, [%{"slug" => "kid", "parent" => %{"id" => root.uuid}}])) ==
             ["updated"]

    assert {:ok, %{"results" => [a, b, c]}} =
             confirmed(g, [
               %{"slug" => "kid", "parent" => %{"slug" => "nope"}},
               %{"slug" => "kid", "parent" => %{"id" => foreign.uuid}},
               %{"slug" => "root", "parent" => %{"slug" => "kid"}}
             ])

    assert [a["error"]["code"], b["error"]["code"], c["error"]["code"]] ==
             ["parent_not_found", "parent_wrong_group", "category_cycle"]
  end

  test "a later row may name an earlier CREATED category as its parent, in the dry run and in the write",
       %{g: g} do
    rows = [
      %{"slug" => "a", "name" => "A"},
      %{"slug" => "b", "name" => "B", "parent" => %{"slug" => "a"}}
    ]

    assert {:preview, %{"rows" => preview}, _} = upsert(g, rows, %{dry_run?: true})
    assert Enum.map(preview, & &1["action"]) == ["created", "created"]
    assert actions(upsert(g, rows)) == ["created", "created"]
    assert stored(g, "b").parent_uuid == stored(g, "a").uuid
  end

  describe "Danger.upsert_categories/2" do
    test "false for creates only and for rows that change nothing; true when a row changes an existing category",
         %{g: g} do
      Fx.category!(g["slug"], "Old", %{slug: "old"})
      input = fn rows -> %{"group" => g["slug"], "categories" => rows} end
      refute Danger.upsert_categories(input.([%{"slug" => "new", "name" => "New"}]), ctx())
      refute Danger.upsert_categories(input.([%{"slug" => "old", "name" => "Old"}]), ctx())

      for change <- [
            %{"name" => "X"},
            %{"description" => "d"},
            %{"position" => 9},
            %{"name_i18n" => %{"de" => "A"}}
          ] do
        assert Danger.upsert_categories(input.([Map.merge(%{"slug" => "old"}, change)]), ctx()),
               inspect(change)
      end
    end

    test "true when a row moves an existing category under a parent", %{g: g} do
      Fx.category!(g["slug"], "Root", %{slug: "root"})
      kid = Fx.category!(g["slug"], "Kid", %{slug: "kid"})
      input = fn rows -> %{"group" => g["slug"], "categories" => rows} end

      assert Danger.upsert_categories(
               input.([%{"slug" => "kid", "parent" => %{"slug" => "root"}}]),
               ctx()
             )

      {:ok, _} = Categories.update_category(kid.uuid, %{"parent_uuid" => stored(g, "root").uuid})

      assert Danger.upsert_categories(input.([%{"slug" => "kid", "parent" => nil}]), ctx())

      refute Danger.upsert_categories(
               input.([%{"slug" => "kid", "parent" => %{"slug" => "root"}}]),
               ctx()
             )
    end

    test "false for an update of a category created earlier in the same request", %{g: g} do
      refute Danger.upsert_categories(
               %{
                 "group" => g["slug"],
                 "categories" => [
                   %{"slug" => "n", "name" => "N"},
                   %{"slug" => "n", "description" => "d"}
                 ]
               },
               ctx()
             )
    end

    test "fail closed: an unresolvable group, a malformed request and a broken categories table answer true",
         %{g: g} do
      assert Danger.upsert_categories(%{"group" => "nope", "categories" => []}, ctx())
      assert Danger.upsert_categories(%{}, ctx())

      TestRepo.query!(
        "ALTER TABLE phoenix_kit_publishing_categories RENAME TO phoenix_kit_publishing_categories_x"
      )

      assert Danger.upsert_categories(
               %{"group" => g["slug"], "categories" => [%{"slug" => "new", "name" => "New"}]},
               ctx()
             ),
             "never 'this row is a create'"
    end
  end

  test "a row that became an update between the plan and the write is refused unconfirmed and applied confirmed",
       %{g: g} do
    flag = make_ref()
    handler = "upsert-cat-#{System.unique_integer([:positive])}"

    # After the plan's read of the categories, another actor creates the slug.
    :telemetry.attach(
      handler,
      TestRepo.config()[:telemetry_prefix] ++ [:query],
      fn _e, _m, meta, _c ->
        if meta.source == "phoenix_kit_publishing_categories" and meta.query =~ "SELECT" and
             Process.get(flag) == nil do
          Process.put(flag, true)
          {:ok, _} = Categories.create_category(g["slug"], %{"name" => "Early", "slug" => "late"})
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert {:ok,
            %{"results" => [%{"action" => "error", "error" => %{"code" => "revision_mismatch"}}]}} =
             upsert(g, [%{"slug" => "late", "name" => "Late"}])

    assert stored(g, "late").name == "Early"

    assert {:ok, %{"results" => [%{"action" => "updated"}]}} =
             upsert(g, [%{"slug" => "late", "name" => "Late"}], %{confirmation_uuid: "c"})

    assert stored(g, "late").name == "Late"
  end

  test "a dry run leaves ALL tables unchanged and shows from/to; the fingerprint follows the category and its published count",
       %{g: g} do
    c = Fx.category!(g["slug"], "Old", %{slug: "old"})
    before = Fx.table_state()

    assert {:preview,
            %{
              "requires_confirmation" => true,
              "rows" => [%{"changes" => %{"name" => %{"from" => "Old", "to" => "New"}}}]
            }, f1} = upsert(g, [%{"id" => c.uuid, "name" => "New"}], %{dry_run?: true})

    assert Fx.table_state() == before
    {:ok, _} = Categories.update_category(c.uuid, %{"description" => "changed meanwhile"})
    assert {:preview, _, f2} = upsert(g, [%{"id" => c.uuid, "name" => "New"}], %{dry_run?: true})
    assert f1 != f2
  end

  test "a trashed group is refused and an unknown group is not_found", %{g: g} do
    assert {:error, :not_found, _, _} =
             ApiCase.call("publishing.upsert_categories", %{
               "group" => "nope",
               "categories" => [%{"slug" => "a", "name" => "A"}]
             })

    {:ok, _} = Groups.trash_group(g["slug"])

    assert {:error, :validation_failed, _, %{errors: [%{reason: "group_trashed"}]}} =
             upsert(g, [%{"slug" => "a", "name" => "A"}])
  end
end
