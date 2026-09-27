defmodule PhoenixKit.Modules.Publishing.Views.VisitorTableTest do
  use ExUnit.Case, async: false

  alias PhoenixKit.Modules.Publishing.Views.VisitorTable

  @table :phoenix_kit_publishing_view_visitors

  setup do
    if Process.whereis(VisitorTable) == nil, do: start_supervised!(VisitorTable)
    day = "cap-test-#{System.unique_integer([:positive])}"
    on_exit(fn -> :ets.match_delete(@table, {{day, :_, :_}, :_}) end)
    %{day: day}
  end

  test "deduplicates a visitor below the cap", %{day: day} do
    assert VisitorTable.first_view_today?("post", "visitor", day)
    refute VisitorTable.first_view_today?("post", "visitor", day)
    assert VisitorTable.first_view_today?("other-post", "visitor", day)
  end

  test "keeps counting at capacity without growing the table", %{day: day} do
    for batch <- 0..49 do
      rows = for n <- 1..10_000, do: {{day, "post", batch * 10_000 + n}, true}
      :ets.insert(@table, rows)
    end

    size = :ets.info(@table, :size)
    assert VisitorTable.first_view_today?("post", "new-visitor", day)
    assert :ets.info(@table, :size) == size
  end
end
