defmodule PhoenixKit.Modules.Publishing.ListingCache.LockTableOwnerTest do
  @moduledoc """
  Regression test for M8 — the regeneration-lock ETS table must be owned by a
  long-lived process, not whichever transient request first creates it. Otherwise
  the table dies with that process and the lock ops 500 a public read.
  """

  use ExUnit.Case, async: false

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
end
