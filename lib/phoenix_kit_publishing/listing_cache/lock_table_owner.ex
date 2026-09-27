defmodule PhoenixKit.Modules.Publishing.ListingCache.LockTableOwner do
  @moduledoc """
  Long-lived owner for the `ListingCache` regeneration-lock ETS table.

  The lock table is `:public`/`:named_table`, but ETS tables are owned by the
  process that creates them. Without a supervised owner it was born in whichever
  transient request process first missed the cache and died with that process —
  after which the lock operations raised `ArgumentError` on the vanished table and
  500'd a public read (M8). Creating it from this supervised GenServer keeps it
  alive for the life of the node; on the rare crash/restart the supervisor brings
  the owner (and table) back, and `ListingCache.ensure_lock_table_exists/0` covers
  the brief gap.

  It is also the one process every WRITE to the listing terms goes through:
  `ListingCache.install_snapshot/4` and `ListingCache.erase_local/1` run their
  check-and-write inside `run_exclusive/1`, so an erase cannot land between a
  regeneration's staleness check and its install. Reads never come here —
  they stay lock-free `:persistent_term` lookups.
  """

  use GenServer

  alias PhoenixKit.Modules.Publishing.ListingCache

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Runs `fun` inside the owner, one caller at a time, and returns its result.

  Exits with `:noproc` when the owner is not running; callers decide what a
  missing owner means for them (`ListingCache` refuses an install and runs an
  erase directly).
  """
  @spec run_exclusive((-> result)) :: result when result: term()
  def run_exclusive(fun) when is_function(fun, 0) do
    GenServer.call(__MODULE__, {:run_exclusive, fun})
  end

  @impl true
  def init(:ok) do
    ListingCache.ensure_lock_table_exists()
    {:ok, %{}}
  end

  @impl true
  def handle_call({:run_exclusive, fun}, _from, state) do
    {:reply, fun.(), state}
  end
end
