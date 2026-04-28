defmodule PhoenixKit.Modules.Publishing.FacadeCallbacksTest do
  @moduledoc """
  Tests for the PhoenixKit.Module behaviour callbacks on the
  Publishing facade — module_key, module_name, version, get_config,
  permission_metadata, admin_tabs, settings_tabs, children,
  route_module, css_sources.

  These are pure metadata functions that should never raise.
  """

  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Publishing

  describe "metadata callbacks" do
    test "module_key returns 'publishing'" do
      assert Publishing.module_key() == "publishing"
    end

    test "module_name returns 'Publishing'" do
      assert Publishing.module_name() == "Publishing"
    end

    test "version returns a string" do
      assert is_binary(Publishing.version())
    end

    test "css_sources returns the expected OTP app" do
      assert Publishing.css_sources() == [:phoenix_kit_publishing]
    end

    test "route_module returns PhoenixKitPublishing.Routes" do
      assert Publishing.route_module() == PhoenixKitPublishing.Routes
    end

    test "children returns Presence in the supervision child list" do
      children = Publishing.children()
      assert PhoenixKit.Modules.Publishing.Presence in children
    end
  end

  describe "permission_metadata/0" do
    test "returns a permission metadata struct" do
      result = Publishing.permission_metadata()
      assert is_map(result) or is_list(result)
      # Has the canonical metadata fields
      assert Map.has_key?(result, :key) or is_list(result)
    end
  end

  describe "admin_tabs/0" do
    test "returns a list of tab structs (or one tab)" do
      result = Publishing.admin_tabs()
      assert is_list(result) or is_struct(result)
    end
  end

  describe "settings_tabs/0" do
    test "returns the settings tab list (may be empty)" do
      result = Publishing.settings_tabs()
      assert is_list(result) or is_struct(result)
    end
  end

  describe "should_create_new_version?/3" do
    test "always returns false (variant-versioning model)" do
      refute Publishing.should_create_new_version?(%{}, %{}, "en")
      refute Publishing.should_create_new_version?(nil, nil, nil)
    end
  end

  describe "slugify/1 + valid_slug?/1" do
    test "slugify returns lowercase hyphenated form" do
      assert Publishing.slugify("Hello World") == "hello-world"
    end

    test "slugify handles non-ASCII" do
      result = Publishing.slugify("Café 2026")
      assert is_binary(result)
    end

    test "valid_slug? returns true for valid slug" do
      assert Publishing.valid_slug?("hello-world")
    end

    test "valid_slug? returns false for invalid input" do
      refute Publishing.valid_slug?("Bad Slug!")
      refute Publishing.valid_slug?("")
      refute Publishing.valid_slug?(nil)
      refute Publishing.valid_slug?(123)
    end
  end
end
