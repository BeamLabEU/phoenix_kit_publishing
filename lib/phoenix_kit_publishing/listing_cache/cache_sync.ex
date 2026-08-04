defmodule PhoenixKit.Modules.Publishing.ListingCache.CacheSync do
  @moduledoc """
  Node-local subscriber that erases this node's cached listing terms when
  another node invalidates a group (rename/trash/delete, category changes).

  `:persistent_term` is process-less: a peer node's warm cache never misses
  on its own, so before this subscriber existed it kept serving pre-mutation
  listings until an unrelated LOCAL mutation happened to regenerate. This
  process is erase-only — the next public read on the node rebuilds lazily
  (with `broadcast: false`), so an invalidation can never start a
  cluster-wide regeneration storm. Not a bottleneck: it holds no hot-path
  state and only reacts to broadcasts.

  Delivery is Phoenix.PubSub at-most-once — a node partitioned when the
  broadcast fires misses the purge until its next local mutation or restart.
  The listing cache is eventually consistent, not strongly.
  """

  use GenServer

  alias PhoenixKit.Modules.Publishing.ListingCache
  alias PhoenixKit.Modules.Publishing.PubSub, as: PublishingPubSub

  def start_link(opts) do
    GenServer.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(:ok) do
    # handle_continue so a slow/absent PubSub manager can't block supervisor
    # startup of the rest of the tree.
    {:ok, %{}, {:continue, :subscribe}}
  end

  @impl true
  def handle_continue(:subscribe, state) do
    PublishingPubSub.subscribe_to_cache_invalidations()
    {:noreply, state}
  end

  @impl true
  def handle_info({:cache_invalidated, group_slug}, state) do
    # erase_local, never invalidate/1 — that would re-broadcast in a loop.
    ListingCache.erase_local(group_slug)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}
end
