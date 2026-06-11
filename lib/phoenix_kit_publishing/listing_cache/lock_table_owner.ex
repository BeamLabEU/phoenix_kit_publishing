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
  """

  use GenServer

  alias PhoenixKit.Modules.Publishing.ListingCache

  def start_link(opts) do
    GenServer.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(:ok) do
    ListingCache.ensure_lock_table_exists()
    {:ok, %{}}
  end
end
