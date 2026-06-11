defmodule PhoenixKit.Modules.Publishing.ListingCache.LockTableOwnerTest do
  @moduledoc """
  Regression test for M8 — the regeneration-lock ETS table must be owned by a
  long-lived process, not whichever transient request first creates it. Otherwise
  the table dies with that process and the lock ops 500 a public read.
  """

  use ExUnit.Case, async: false

  alias PhoenixKit.Modules.Publishing.ListingCache
  alias PhoenixKit.Modules.Publishing.ListingCache.LockTableOwner

  @lock_table :phoenix_kit_listing_cache_locks

  test "starting the owner makes the lock table exist, owned by a live process" do
    {:ok, pid} =
      LockTableOwner.start_link(name: :"lock_owner_#{System.unique_integer([:positive])}")

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    assert :ets.whereis(@lock_table) != :undefined

    # The table must be owned by a LIVE process — the bug was a transient request
    # process owning it and dying, leaving a dangling named table.
    owner = :ets.info(@lock_table, :owner)
    assert is_pid(owner) and Process.alive?(owner)
  end

  test "a superseded holder's token-scoped release leaves a takeover lock intact (L10)" do
    # Pins the contract do_regenerate_with_lock/2's release relies on: the lock
    # value is {timestamp, token}, and a release matched on a stale token is a
    # no-op — so a slow original holder can't delete a takeover holder's lock.
    ListingCache.ensure_lock_table_exists()
    group = "l10-#{System.unique_integer([:positive])}"
    token_a = make_ref()
    token_b = make_ref()

    # B took over with a fresh token after A went stale.
    :ets.insert(@lock_table, {group, {1, token_b}})

    # A's release (token_a) must delete nothing and leave B's lock untouched.
    assert :ets.select_delete(@lock_table, [{{group, {:_, token_a}}, [], [true]}]) == 0
    assert :ets.lookup(@lock_table, group) == [{group, {1, token_b}}]

    # B's own release cleanly removes its lock.
    assert :ets.select_delete(@lock_table, [{{group, {:_, token_b}}, [], [true]}]) == 1
    assert :ets.lookup(@lock_table, group) == []
  end
end
