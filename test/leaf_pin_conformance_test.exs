defmodule PhoenixKitPublishing.LeafPinConformanceTest do
  use ExUnit.Case, async: true

  test "Leaf supports correlated flushes without excluding later 0.x minors" do
    {:leaf, requirement} =
      Enum.find(Mix.Project.config()[:deps], &(elem(&1, 0) == :leaf))

    for version <- ["0.4.1", "0.5.0", "1.0.0"] do
      refute Version.match?(version, requirement)
    end

    for version <- ["0.5.1", "0.5.2", "0.6.0", "0.99.0"] do
      assert Version.match?(version, requirement)
    end
  end
end
