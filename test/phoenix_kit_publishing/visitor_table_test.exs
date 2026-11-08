defmodule PhoenixKit.Modules.Publishing.Views.VisitorTableTest do
  use ExUnit.Case, async: false

  alias PhoenixKit.Modules.Publishing.Views.VisitorTable

  @table :phoenix_kit_publishing_view_visitors

  setup do
    if Process.whereis(VisitorTable) == nil, do: start_supervised!(VisitorTable)
    day = "cap-test-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      :ets.match_delete(@table, {{day, :_, :_}, :_})
      :ets.delete(@table, {:count, day})
      :ets.delete(@table, {:count, "0000-" <> day})
    end)

    %{day: day}
  end

  test "deduplicates a visitor below the cap", %{day: day} do
    assert VisitorTable.first_view_today?("post", "visitor", day)
    refute VisitorTable.first_view_today?("post", "visitor", day)
    assert VisitorTable.first_view_today?("other-post", "visitor", day)
  end

  test "keeps counting at the day's capacity without growing the table", %{day: day} do
    :ets.insert(@table, {{:count, day}, 500_000})

    size = :ets.info(@table, :size)
    assert VisitorTable.first_view_today?("post", "new-visitor", day)
    assert VisitorTable.first_view_today?("post", "new-visitor", day)
    assert :ets.info(@table, :size) == size
  end

  # The cap is per day: yesterday's full table must not switch today's dedup off.
  test "a full earlier day does not cap today", %{day: day} do
    :ets.insert(@table, {{:count, "0000-#{day}"}, 500_000})

    assert VisitorTable.first_view_today?("post", "visitor", day)
    refute VisitorTable.first_view_today?("post", "visitor", day)
  end

  test "the sweep removes earlier days' rows and counters, not today's" do
    VisitorTable.first_view_today?("post", "old", "2000-01-01")
    VisitorTable.first_view_today?("post", "new", "2999-01-01")

    VisitorTable.sweep("2500-01-01")

    assert :ets.lookup(@table, {"2000-01-01", "post", "old"}) == []
    assert :ets.lookup(@table, {:count, "2000-01-01"}) == []
    assert [_] = :ets.lookup(@table, {"2999-01-01", "post", "new"})
    :ets.match_delete(@table, {{"2999-01-01", :_, :_}, :_})
    :ets.delete(@table, {:count, "2999-01-01"})
  end

  test "the sweep is timed to the next UTC midnight" do
    assert VisitorTable.ms_until_next_utc_midnight(~U[2026-11-08 23:59:59.000Z]) == 1_000
    assert VisitorTable.ms_until_next_utc_midnight(~U[2026-11-08 00:00:00.000Z]) == 86_400_000
  end
end
