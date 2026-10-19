defmodule PhoenixKit.Modules.Publishing.API.GateTest do
  use ExUnit.Case, async: true

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

  test "the gate looks at the loaded core" do
    assert Gate.available?() ==
             Enum.all?(
               [{PhoenixKit.API.Keys, :active?, 1}, {PhoenixKit.API.Flow, :gate, 1}],
               &Gate.available?/1
             )

    refute Gate.available?({Enum, :no_such_function, 7})
    refute Gate.available?({NoSuchModule, :x, 0})
  end

  test "the gated list is exactly the five reads and create_version" do
    assert Enum.sort(Enum.map(API.tools(false), & &1.name)) == Enum.sort(@reads_and_safe)
  end
end
