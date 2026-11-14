defmodule PhoenixKit.Modules.Publishing.CustomFieldsTest do
  @moduledoc """
  Per-post custom fields (version data `custom_fields`): normalisation, the
  write path through `Posts.update_post/4`, the read path on the post map,
  and the machine API.
  """

  use PhoenixKitPublishing.DataCase, async: false

  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.{DBStorage, Groups, Posts, PublishingVersion}

  describe "normalize_custom_fields/1" do
    test "keys are normalised, blanks dropped, bad bytes removed, values cut, the count capped" do
      assert PublishingVersion.normalize_custom_fields(%{
               " Release Version " => " 0.33.0 ",
               "pkg-name" => "projects",
               "blank" => "  ",
               "" => "no key",
               "n" => 3,
               "flag" => true,
               "nul" => "a" <> <<0>> <> "b",
               "bad" => <<255, 254>>,
               "list" => ["x"]
             }) == %{
               "release_version" => "0.33.0",
               "pkg_name" => "projects",
               "n" => "3",
               "flag" => "true",
               "nul" => "ab"
             }

      long = String.duplicate("é", 2_100)
      assert %{"k" => cut} = PublishingVersion.normalize_custom_fields(%{"k" => long})
      assert String.length(cut) == 2_000

      many = Map.new(1..40, &{"f#{String.pad_leading(to_string(&1), 2, "0")}", "v"})
      assert map_size(PublishingVersion.normalize_custom_fields(many)) == 30

      # the editor's rows: a later row wins
      assert PublishingVersion.normalize_custom_fields([
               %{"key" => "a", "value" => "1"},
               %{"key" => "A", "value" => "2"}
             ]) == %{"a" => "2"}

      assert PublishingVersion.normalize_custom_fields(nil) == %{}
      assert PublishingVersion.normalize_custom_fields("x") == %{}
    end
  end

  test "update_post replaces the map, an empty one clears it; the post map carries it" do
    {:ok, group} = Groups.add_group("cf-#{System.unique_integer([:positive])}", mode: "slug")
    slug = group["slug"]
    {:ok, post} = Posts.create_post(slug, %{title: "Release", slug: "release", content: "Body."})

    {:ok, _} =
      Posts.update_post(
        slug,
        post,
        %{"custom_fields" => %{"package" => "billing", "version" => "1.0"}},
        %{publish: false}
      )

    assert DBStorage.get_version(post[:uuid], 1).data["custom_fields"] ==
             %{"package" => "billing", "version" => "1.0"}

    {:ok, read} = Posts.read_post(slug, post[:uuid])
    assert read.metadata.custom_fields == %{"package" => "billing", "version" => "1.0"}

    # a save that does not mention them leaves them alone
    {:ok, _} = Posts.update_post(slug, read, %{"title" => "Release 1.0"}, %{publish: false})
    assert DBStorage.get_version(post[:uuid], 1).data["custom_fields"]["version"] == "1.0"

    {:ok, read} = Posts.read_post(slug, post[:uuid])
    {:ok, _} = Posts.update_post(slug, read, %{"custom_fields" => %{}}, %{publish: false})
    refute Map.has_key?(DBStorage.get_version(post[:uuid], 1).data, "custom_fields")

    assert [%{metadata: %{custom_fields: %{}}}] = Publishing.list_posts(slug)
  end
end
