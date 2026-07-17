defmodule PhoenixKit.Modules.Publishing.GroupSettingsTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.GroupSettings
  alias PhoenixKit.Modules.Publishing.PublishingGroup

  describe "schema/0" do
    test "every entry carries the required fields with sane types" do
      for s <- GroupSettings.schema() do
        assert is_binary(s.key)
        assert s.type in [:enum, :boolean]
        assert is_list(s.allowed)
        assert s.scope in [:listing, :post, :appearance]
        assert is_binary(s.label)
        assert is_binary(s.description)
        assert is_nil(s.depends_on) or is_binary(s.depends_on)
        # The default must itself be a valid value.
        assert s.default in s.allowed
      end
    end

    test "covers exactly the keys update_group/3 persists to group data" do
      # Compares against the REAL write path (Groups.config_setting_keys/0 is
      # the list merge_group_config/2 iterates), not a hand-maintained copy —
      # adding a setting to the write path without the spec (or vice versa)
      # fails here.
      assert Enum.sort(GroupSettings.keys()) == Enum.sort(Groups.config_setting_keys())
    end

    test "any dependency references a real setting key" do
      keys = MapSet.new(GroupSettings.keys())

      for %{depends_on: dep} <- GroupSettings.schema(), not is_nil(dep) do
        assert MapSet.member?(keys, dep), "depends_on #{inspect(dep)} is not a known setting"
      end
    end
  end

  describe "default_config/0" do
    test "matches the schema accessors' defaults on an empty group (no drift)" do
      empty = %PublishingGroup{data: %{}}
      defaults = GroupSettings.default_config()

      assert defaults["featured_enabled"] == PublishingGroup.featured_enabled?(empty)
      assert defaults["featured_layout"] == PublishingGroup.featured_layout(empty)
      assert defaults["scrollbar_style"] == PublishingGroup.scrollbar_style(empty)

      assert defaults["scroll_progress_enabled"] ==
               PublishingGroup.scroll_progress_enabled?(empty)

      assert defaults["scroll_headings_enabled"] ==
               PublishingGroup.scroll_headings_enabled?(empty)

      assert defaults["scroll_timeline_enabled"] ==
               PublishingGroup.scroll_timeline_enabled?(empty)

      assert defaults["scroll_timeline_granularity"] ==
               PublishingGroup.scroll_timeline_granularity(empty)

      assert defaults["listing_sort"] == PublishingGroup.listing_sort(empty)
      assert defaults["show_breadcrumbs"] == PublishingGroup.show_breadcrumbs?(empty)
      assert defaults["post_date_position"] == PublishingGroup.post_date_position(empty)
      assert defaults["post_width"] == PublishingGroup.post_width(empty)
      assert defaults["show_featured_image"] == PublishingGroup.show_featured_image?(empty)
      assert defaults["show_reading_time"] == PublishingGroup.show_reading_time?(empty)
      assert defaults["show_tags"] == PublishingGroup.show_tags?(empty)
      assert defaults["show_post_count"] == PublishingGroup.show_post_count?(empty)
    end

    test "covers every schema key (no accessor-parity blind spots)" do
      assert Enum.sort(Map.keys(GroupSettings.default_config())) ==
               Enum.sort(GroupSettings.keys())
    end
  end

  describe "validate_params/1" do
    test "normalizes booleans and enums and preserves unknown keys" do
      params = %{
        "post_width" => "wide",
        "show_tags" => "true",
        "featured_enabled" => false,
        # not governed by this module — must pass through untouched
        "name" => "My Blog"
      }

      assert {:ok, out} = GroupSettings.validate_params(params)
      assert out["post_width"] == "wide"
      assert out["show_tags"] == true
      assert out["featured_enabled"] == false
      assert out["name"] == "My Blog"
    end

    test "accepts on/off and true/false string forms for booleans" do
      assert {:ok, %{"show_tags" => true}} = GroupSettings.validate_params(%{"show_tags" => "on"})

      assert {:ok, %{"show_tags" => false}} =
               GroupSettings.validate_params(%{"show_tags" => "off"})
    end

    test "rejects an out-of-range enum value with a helpful reason" do
      assert {:error, [%{key: "post_width", reason: reason}]} =
               GroupSettings.validate_params(%{"post_width" => "gigantic"})

      assert reason =~ "narrow"
    end

    test "rejects a non-boolean value for a boolean setting" do
      assert {:error, [%{key: "show_tags", reason: reason}]} =
               GroupSettings.validate_params(%{"show_tags" => "maybe"})

      assert reason =~ "boolean"
    end

    test "reports every invalid key at once" do
      assert {:error, errors} =
               GroupSettings.validate_params(%{
                 "post_width" => "gigantic",
                 "listing_sort" => "sideways"
               })

      assert length(errors) == 2
      assert Enum.map(errors, & &1.key) |> Enum.sort() == ["listing_sort", "post_width"]
    end

    test "normalizes atom keys to the canonical string keys update_group/3 matches" do
      # update_group/3 only matches string keys — if the validated result kept
      # atom keys, feeding it to update_group would silently persist nothing.
      assert {:ok, out} =
               GroupSettings.validate_params(%{post_width: "wide", show_tags: true})

      assert out == %{"post_width" => "wide", "show_tags" => true}
      refute Map.has_key?(out, :post_width)
    end

    test "accepts atom enum values, normalizing to strings" do
      assert {:ok, %{"post_width" => "wide"}} =
               GroupSettings.validate_params(%{"post_width" => :wide})
    end

    test "returns an error (not a crash) for non-castable enum values" do
      # A map has no String.Chars impl — must come back as {:error, _}, not
      # raise Protocol.UndefinedError.
      assert {:error, [%{key: "post_width"}]} =
               GroupSettings.validate_params(%{"post_width" => %{"evil" => true}})

      assert {:error, [%{key: "listing_sort"}]} =
               GroupSettings.validate_params(%{"listing_sort" => [1, 2, 3]})
    end

    test "passes unknown non-string keys through untouched" do
      assert {:ok, out} = GroupSettings.validate_params(%{"slug" => "blog", name: "My Blog"})
      assert out[:name] == "My Blog"
      assert out["slug"] == "blog"
    end
  end
end
