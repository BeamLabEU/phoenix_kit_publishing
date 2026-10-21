defmodule PhoenixKit.Modules.Publishing.API.GateTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias PhoenixKit.Modules.Publishing.API
  alias PhoenixKit.Modules.Publishing.API.{Gate, Tools}

  @reads_and_safe ~w(publishing.list_groups publishing.get_group_settings_schema publishing.list_posts
                     publishing.get_post publishing.list_categories publishing.create_version)

  test "without the confirmation flow only the tools without danger are exposed" do
    names = API.tools(false) |> Enum.map(& &1.name)
    assert names == for(tool <- Tools.all(), tool.danger == nil, do: tool.name)
    assert Enum.all?(API.tools(false), &(&1.danger == nil))
    assert names -- @reads_and_safe == []
  end

  test "with the flow every declared tool is exposed" do
    assert API.tools(true) == Tools.all()
  end

  test "an open gate logs nothing" do
    :persistent_term.erase({API, :withheld_logged})
    assert capture_log([level: :warning], fn -> API.tools(true) end) == ""
  end

  test "the gate asks for exactly the two functions of the confirmation flow" do
    assert Gate.markers() == [{PhoenixKit.API.Keys, :active?, 1}, {PhoenixKit.API.Flow, :gate, 1}]
  end

  test "the gate looks at the loaded core" do
    assert Gate.available?()
    refute Gate.available?({Enum, :no_such_function, 7})
    refute Gate.available?({NoSuchModule, :x, 0})
  end

  describe "a core that lacks a marker" do
    setup do
      Application.put_env(:phoenix_kit_publishing, :gate_extra_markers, [{NoSuchModule, :x, 0}])
      on_exit(fn -> Application.delete_env(:phoenix_kit_publishing, :gate_extra_markers) end)
    end

    test "warns once that tools are withheld and names the missing function" do
      :persistent_term.erase({API, :withheld_logged})
      on_exit(fn -> :persistent_term.erase({API, :withheld_logged}) end)

      log = capture_log([level: :warning], fn -> API.tools() end)
      assert log =~ "withheld"
      assert log =~ "NoSuchModule"

      assert capture_log([level: :warning], fn -> API.tools() end) == ""
    end

    test "closes the gate and tools/0 withholds every tool with a danger" do
      refute Gate.available?()
      assert Enum.sort(Enum.map(API.tools(), & &1.name)) == Enum.sort(@reads_and_safe)
    end
  end

  test "with the gate open tools/0 exposes every declared tool" do
    assert API.tools() == Tools.all()
  end

  test "the gated list is exactly the five reads and create_version" do
    assert Enum.sort(Enum.map(API.tools(false), & &1.name)) == Enum.sort(@reads_and_safe)
  end
end
