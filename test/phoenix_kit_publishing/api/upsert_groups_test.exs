defmodule PhoenixKit.Modules.Publishing.API.UpsertGroupsTest do
  use PhoenixKit.DataCase, async: false

  import PhoenixKitPublishing.ActivityLogAssertions

  alias PhoenixKit.Modules.Publishing.API.{Danger, Schemas, Tools, UpsertGroups}
  alias PhoenixKit.Modules.Publishing.{Constants, Groups, GroupSettings}
  alias PhoenixKitPublishing.Test.ApiCase
  alias PhoenixKitPublishing.Test.ApiFixtures, as: Fx
  alias PhoenixKitPublishing.Test.Repo, as: TestRepo

  defp ctx, do: ApiCase.ctx(%{dry_run?: true})

  setup do
    Fx.languages!()
    :ok
  end

  defp upsert(rows, overrides \\ %{}),
    do: ApiCase.call("publishing.upsert_groups", %{"groups" => rows}, overrides)

  # What core hands the handler once the owner confirmed: changing an existing group is a
  # confirmed write.
  defp confirmed(rows), do: upsert(rows, %{confirmation_uuid: "c"})

  defp group(slug), do: elem(Groups.fetch_group(slug), 1)

  defp action(result),
    do: result |> elem(1) |> Map.fetch!("results") |> hd() |> Map.fetch!("action")

  defp error_codes(result),
    do:
      result
      |> elem(1)
      |> Map.fetch!("results")
      |> Enum.map(&(&1["error"] && &1["error"]["code"]))

  test "creating a mode: slug group yields a slug group, while its activity row has mode auto" do
    assert {:ok, %{"results" => [%{"action" => "created", "id" => id}]}} =
             upsert([%{"slug" => "docs", "name" => "Docs", "mode" => "slug"}])

    assert group("docs")["mode"] == "slug"
    row = assert_activity_logged("publishing.group.created", resource_uuid: id)
    assert row.mode == "auto" and row.metadata["via"] == "api"
    assert row.metadata["tool"] == "publishing.upsert_groups"
  end

  test "a retried create converges: unchanged for the group's own mode, type and item names" do
    row = %{
      "slug" => "docs",
      "name" => "Docs",
      "mode" => "slug",
      "type" => "faq",
      "item_singular" => "entry",
      "item_plural" => "entries"
    }

    assert action(upsert([row])) == "created"
    assert action(upsert([row])) == "unchanged"
  end

  test "mode, type and item names are fixed at creation: a different value is mode_locked or immutable_field" do
    {:ok, _} = upsert([%{"slug" => "docs", "name" => "Docs", "mode" => "slug"}])

    assert error_codes(upsert([%{"slug" => "docs", "mode" => "timestamp"}])) == ["mode_locked"]
    assert error_codes(upsert([%{"slug" => "docs", "type" => "faq"}])) == ["immutable_field"]

    assert error_codes(upsert([%{"slug" => "docs", "item_singular" => "thing"}])) ==
             ["immutable_field"]

    assert error_codes(upsert([%{"slug" => "docs", "item_plural" => "things"}])) ==
             ["immutable_field"]
  end

  test "settings: a valid value is stored; a wrong enum is invalid_setting; a mistyped key is refused by the schema" do
    {:ok, _} = upsert([%{"slug" => "docs", "name" => "Docs", "mode" => "slug"}])
    width = Enum.find(Constants.post_widths(), &(&1 != group("docs")["post_width"]))

    assert action(
             confirmed([
               %{
                 "slug" => "docs",
                 "settings" => %{"show_breadcrumbs" => true, "post_width" => width}
               }
             ])
           ) == "updated"

    assert group("docs")["show_breadcrumbs"] == true
    assert group("docs")["post_width"] == width

    # The input schema lists the allowed values, so a wrong enum is refused for the whole request.
    assert {:error, :validation_failed, _, _} =
             confirmed([%{"slug" => "docs", "settings" => %{"post_width" => "gigantic"}}])

    assert {:error, :validation_failed, _, _} =
             upsert([%{"slug" => "docs", "settings" => %{"show_breadcrumbz" => true}}])
  end

  test "settings are validated by GroupSettings before the call: a wrong value is an invalid_setting row, not a silent drop" do
    {:ok, _} = upsert([%{"slug" => "docs", "name" => "Docs", "mode" => "slug"}])
    before = group("docs")

    # Straight into the handler, past the schema: the module would otherwise ignore the wrong enum
    # and answer "updated".
    rows = [
      %{"slug" => "docs", "settings" => %{"post_width" => "gigantic"}},
      %{
        "slug" => "docs2",
        "name" => "Two",
        "mode" => "slug",
        "settings" => %{"show_breadcrumbs" => "maybe"}
      },
      %{"slug" => "docs3", "name" => "Three", "settings" => "nope"}
    ]

    assert {:ok, %{"results" => results}} =
             UpsertGroups.call(
               %{"groups" => rows},
               ApiCase.ctx(%{confirmation_uuid: "c"})
             )

    assert Enum.map(results, & &1["error"]["code"]) ==
             ["invalid_setting"] ++ ["invalid_setting", "invalid_setting"]

    assert group("docs") == before
    assert Groups.fetch_group("docs2") == {:error, :not_found}
  end

  test "settings and name_i18n of a NEW group are applied by a second update" do
    assert action(
             upsert([
               %{
                 "slug" => "docs",
                 "name" => "Docs",
                 "mode" => "slug",
                 "name_i18n" => %{"de" => "Dokumente"},
                 "settings" => %{"show_breadcrumbs" => true}
               }
             ])
           ) == "created"

    g = group("docs")
    assert g["show_breadcrumbs"] == true and g["name_i18n"] == %{"de" => "Dokumente"}
  end

  test "name_i18n merges per key, a blank value deletes the key, an identical map is unchanged" do
    {:ok, _} =
      upsert([
        %{
          "slug" => "docs",
          "name" => "Docs",
          "mode" => "slug",
          "name_i18n" => %{"de" => "A", "fr" => "B"}
        }
      ])

    assert action(confirmed([%{"slug" => "docs", "name_i18n" => %{"de" => "X"}}])) == "updated"
    assert group("docs")["name_i18n"] == %{"de" => "X", "fr" => "B"}
    assert action(confirmed([%{"slug" => "docs", "name_i18n" => %{"fr" => ""}}])) == "updated"
    assert group("docs")["name_i18n"] == %{"de" => "X"}
    assert action(confirmed([%{"slug" => "docs", "name_i18n" => %{"de" => "X"}}])) == "unchanged"
  end

  test "a name with surrounding blanks converges: the trimmed name is what is compared" do
    {:ok, _} = upsert([%{"slug" => "docs", "name" => " Docs ", "mode" => "slug"}])
    assert group("docs")["name"] == "Docs"
    assert action(upsert([%{"slug" => "docs", "name" => "  Docs"}])) == "unchanged"
  end

  test "row errors: a trashed group, a new group without a name, a bad slug, a duplicate slug" do
    {:ok, _} = upsert([%{"slug" => "gone", "name" => "Gone", "mode" => "slug"}])
    {:ok, _} = Groups.trash_group("gone")
    assert error_codes(upsert([%{"slug" => "gone", "name" => "Back"}])) == ["group_trashed"]

    result =
      upsert([
        %{"slug" => "nameless"},
        %{"slug" => "Bad Slug", "name" => "x"},
        %{"slug" => "admin", "name" => "x"},
        %{"slug" => "dup", "name" => "D", "mode" => "slug"},
        %{"slug" => "dup", "name" => "D2"},
        %{"name" => "No slug"}
      ])

    assert error_codes(result) ==
             [
               "invalid_name",
               "invalid_slug",
               "reserved_route_word",
               nil,
               "invalid_ref",
               "invalid_ref"
             ]
  end

  test "a bad mode or type of a new group is an invalid_mode / invalid_type row" do
    assert error_codes(upsert([%{"slug" => "a", "name" => "A", "mode" => "weekly"}])) ==
             ["invalid_mode"]

    assert error_codes(upsert([%{"slug" => "b", "name" => "B", "type" => "!!!"}])) ==
             ["invalid_type"]

    assert Groups.fetch_group("a") == {:error, :not_found}
    assert Groups.fetch_group("b") == {:error, :not_found}
  end

  test "a NUL byte, a blank name and an over-long value are row errors before any write" do
    too_long = String.duplicate("n", Constants.max_group_name_length() + 1)

    result =
      upsert([
        %{"slug" => "nul", "name" => "A" <> <<0>>},
        %{"slug" => "nul2", "name" => "N", "item_singular" => "x" <> <<0>>},
        %{"slug" => "long", "name" => too_long},
        %{"slug" => "blank", "name" => "   "},
        %{"slug" => "i18n", "name" => "I", "name_i18n" => %{"de" => <<0>>}},
        %{"slug" => "nul" <> <<0>>, "name" => "S"}
      ])

    assert error_codes(result) ==
             [
               "validation_failed",
               "validation_failed",
               "validation_failed",
               "invalid_name",
               "validation_failed",
               "invalid_slug"
             ]

    assert Enum.all?(
             ~w(nul nul2 long blank i18n),
             &(Groups.fetch_group(&1) == {:error, :not_found})
           )
  end

  describe "Danger.upsert_groups/2" do
    setup do
      {:ok, _} = upsert([%{"slug" => "docs", "name" => "Docs", "mode" => "slug"}])
      :ok
    end

    test "false for creates and for rows that change nothing; true when an existing group changes" do
      refute Danger.upsert_groups(
               %{"groups" => [%{"slug" => "new", "name" => "New", "mode" => "slug"}]},
               ctx()
             )

      refute Danger.upsert_groups(%{"groups" => [%{"slug" => "docs", "name" => "Docs"}]}, ctx())

      assert Danger.upsert_groups(
               %{"groups" => [%{"slug" => "docs", "name" => "Renamed"}]},
               ctx()
             )

      assert Danger.upsert_groups(
               %{"groups" => [%{"slug" => "docs", "settings" => %{"show_breadcrumbs" => true}}]},
               ctx()
             )

      assert Danger.upsert_groups(
               %{"groups" => [%{"slug" => "docs", "name_i18n" => %{"de" => "Dokumente"}}]},
               ctx()
             )
    end

    test "rows that fail or that are unchanged next to a create do not make the request dangerous" do
      refute Danger.upsert_groups(
               %{
                 "groups" => [
                   %{"slug" => "new", "name" => "New"},
                   %{"slug" => "docs", "mode" => "timestamp"},
                   %{"slug" => "nameless"}
                 ]
               },
               ctx()
             )
    end

    test "fail closed: a malformed request and a broken groups table answer true" do
      assert Danger.upsert_groups(%{}, ctx())
      assert Danger.upsert_groups(%{"groups" => "nope"}, ctx())

      TestRepo.query!(
        "ALTER TABLE phoenix_kit_publishing_groups RENAME TO phoenix_kit_publishing_groups_x"
      )

      assert Danger.upsert_groups(%{"groups" => [%{"slug" => "new", "name" => "New"}]}, ctx())
    end
  end

  test "a row that became an update between the plan and the write is refused unconfirmed" do
    flag = make_ref()
    handler = "upsert-groups-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      TestRepo.config()[:telemetry_prefix] ++ [:query],
      fn _event, _measurements, meta, _config ->
        if meta.source == "phoenix_kit_publishing_groups" and meta.query =~ "SELECT" and
             Process.get(flag) == nil do
          Process.put(flag, true)
          {:ok, _} = Groups.add_group("Early", slug: "race", mode: "slug")
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert error_codes(upsert([%{"slug" => "race", "name" => "Late", "mode" => "slug"}])) ==
             ["revision_mismatch"]

    assert group("race")["name"] == "Early"
  end

  test "an update unconfirmed at the write is refused row by row and nothing is written" do
    {:ok, _} = upsert([%{"slug" => "docs", "name" => "Docs", "mode" => "slug"}])
    assert error_codes(upsert([%{"slug" => "docs", "name" => "New"}])) == ["revision_mismatch"]
    assert group("docs")["name"] == "Docs"
  end

  test "a dry run leaves ALL tables unchanged and shows from/to; the fingerprint follows the group" do
    {:ok, _} = upsert([%{"slug" => "docs", "name" => "Docs", "mode" => "slug"}])
    before = Fx.table_state()

    assert {:preview,
            %{
              "requires_confirmation" => true,
              "rows" => [%{"changes" => %{"name" => %{"from" => "Docs", "to" => "New"}}}]
            }, f1} = upsert([%{"slug" => "docs", "name" => "New"}], %{dry_run?: true})

    assert Fx.table_state() == before
    {:ok, _} = Groups.update_group("docs", %{"show_breadcrumbs" => true})
    assert {:preview, _, f2} = upsert([%{"slug" => "docs", "name" => "New"}], %{dry_run?: true})
    assert f1 != f2

    {:ok, _} = Groups.update_group("docs", %{"name" => "Other"})
    assert {:preview, _, f3} = upsert([%{"slug" => "docs", "name" => "New"}], %{dry_run?: true})
    assert f2 != f3
  end

  test "a dry run of a create does not require a confirmation and writes nothing" do
    before = Fx.table_state()

    assert {:preview, %{"requires_confirmation" => false, "rows" => [%{"action" => "created"}]},
            _} =
             upsert([%{"slug" => "docs", "name" => "Docs", "mode" => "slug"}], %{dry_run?: true})

    assert Fx.table_state() == before
  end

  test "the closed settings object has exactly the GroupSettings keys" do
    assert Schemas.group_settings()["properties"] |> Map.keys() |> Enum.sort() ==
             Enum.sort(GroupSettings.keys())

    assert Schemas.group_settings()["additionalProperties"] == false
    tool = Enum.find(Tools.all(), &(&1.name == "publishing.upsert_groups"))

    assert get_in(tool.input_schema, ["properties", "groups", "items", "properties", "settings"]) ==
             Schemas.group_settings()
  end

  test "more than 20 rows are refused by max_items" do
    assert {:error, :validation_failed, _, _} =
             upsert(for(n <- 1..21, do: %{"slug" => "g#{n}", "name" => "G"}))

    assert {:ok, %{"summary" => %{"created" => 20}}} =
             upsert(for(n <- 1..20, do: %{"slug" => "g#{n}", "name" => "G", "mode" => "slug"}))
  end
end
