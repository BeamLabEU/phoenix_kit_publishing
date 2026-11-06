defmodule PhoenixKitPublishing.LeafPinConformanceTest do
  use ExUnit.Case, async: true

  # 0.9.0 is the first Leaf with `tag_previews` and `media_url`, which the editor
  # passes on every render. 0.10.1 is the floor because 0.10.0's new escaping came
  # with bugs this editor walks straight into: text from `insert_markdown` (the
  # component toolbar) could arrive backslash-escaped, and text typed after a
  # `[[…]]` link was dropped on save.
  test "Leaf has tag previews and the 0.10.1 fixes, without excluding later 0.x minors" do
    {:leaf, requirement} =
      Enum.find(Mix.Project.config()[:deps], &(elem(&1, 0) == :leaf))

    for version <- ["0.5.1", "0.8.0", "0.9.0", "0.10.0", "1.0.0"] do
      refute Version.match?(version, requirement)
    end

    for version <- ["0.10.1", "0.10.2", "0.11.0", "0.99.0"] do
      assert Version.match?(version, requirement)
    end
  end
end
