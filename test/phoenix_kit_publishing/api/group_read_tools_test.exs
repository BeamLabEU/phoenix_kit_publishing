defmodule PhoenixKit.Modules.Publishing.API.GroupReadToolsTest do
  use PhoenixKit.DataCase, async: false

  alias Ecto.Adapters.SQL
  alias PhoenixKit.Modules.Publishing.DBStorage
  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.GroupSettings
  alias PhoenixKitPublishing.Test.ApiCase
  alias PhoenixKitPublishing.Test.ApiFixtures, as: Fx
  alias PhoenixKitPublishing.Test.Repo

  describe "publishing.list_groups" do
    test "lists active groups with settings and post counts; trashed ones by status" do
      g = Fx.group!(name: "Read Group", mode: "slug")
      Fx.post!(g["slug"], %{title: "One", slug: "one"})
      other = Fx.group!()
      {:ok, _} = Groups.trash_group(other["slug"])

      assert {:ok, %{"groups" => groups, "count" => count}} =
               ApiCase.call("publishing.list_groups", %{})

      row = Enum.find(groups, &(&1["slug"] == g["slug"]))
      assert count == length(groups)
      assert row["post_count"] == 1
      assert row["mode"] == "slug"
      assert row["status"] == "active"
      assert Map.keys(row["settings"]) |> Enum.sort() == Enum.sort(GroupSettings.keys())
      refute Enum.any?(groups, &(&1["slug"] == other["slug"]))

      assert {:ok, %{"groups" => trashed}} =
               ApiCase.call("publishing.list_groups", %{"status" => "trashed"})

      assert Enum.any?(trashed, &(&1["slug"] == other["slug"]))
    end

    test "reads a stale group as stored: the row is not repaired by the read" do
      g = Fx.group!()

      SQL.query!(
        Repo,
        "UPDATE phoenix_kit_publishing_groups SET data = jsonb_set(coalesce(data, '{}'::jsonb), '{type}', '\"bogus\"') WHERE slug = $1",
        [g["slug"]]
      )

      before = DBStorage.get_group_by_slug(g["slug"])
      assert before.data["type"] == "bogus"

      assert {:ok, %{"groups" => groups}} = ApiCase.call("publishing.list_groups", %{})
      assert Enum.find(groups, &(&1["slug"] == g["slug"]))["type"] == "bogus"

      after_read = DBStorage.get_group_by_slug(g["slug"])
      assert after_read.data == before.data
      assert after_read.updated_at == before.updated_at
    end

    test "an unknown status is a validation error from the schema" do
      assert {:error, :validation_failed, _, _} =
               ApiCase.call("publishing.list_groups", %{"status" => "bogus"})
    end

    test "an empty install answers an empty list" do
      assert {:ok, %{"groups" => [], "count" => 0}} = ApiCase.call("publishing.list_groups", %{})
    end
  end

  describe "publishing.get_group_settings_schema" do
    test "answers the machine-readable settings, defaults and the group fields" do
      assert {:ok,
              %{
                "settings" => settings,
                "defaults" => defaults,
                "group_fields" => ["name", "name_i18n"]
              }} =
               ApiCase.call("publishing.get_group_settings_schema", %{})

      assert Enum.map(settings, & &1["key"]) == GroupSettings.keys()
      assert defaults == GroupSettings.default_config()
      assert {:ok, _} = Jason.encode(settings)
      assert Enum.all?(settings, &is_binary(&1["type"]))
    end

    test "takes no input" do
      assert {:error, :validation_failed, _, _} =
               ApiCase.call("publishing.get_group_settings_schema", %{"x" => 1})
    end
  end
end
