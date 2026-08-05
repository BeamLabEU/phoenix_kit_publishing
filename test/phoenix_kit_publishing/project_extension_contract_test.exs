defmodule PhoenixKit.Modules.Publishing.ProjectExtensionContractTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Publishing

  # The phoenix_kit_projects hub discovers this duck-typed catalog entry;
  # pin the shape so a rename doesn't silently drop the Docs tab. Groups
  # are slug-keyed across this package, so the config stores the SLUG.
  test "phoenix_kit_project_extensions/0 declares the Docs tab" do
    assert [ext] = Publishing.phoenix_kit_project_extensions()
    assert ext.key == "publishing_docs"
    assert ext.module_key == "publishing"
    refute ext.default_enabled
    assert [%{key: "docs", lv: lv}] = ext.tabs
    assert Code.ensure_loaded?(lv)
    assert [%{key: "group_slug"}] = ext.config_schema
  end
end
