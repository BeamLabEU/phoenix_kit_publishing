defmodule PhoenixKit.Modules.Publishing.GroupSlugs do
  @moduledoc """
  The set of every group slug (trashed groups too, since a trashed group
  still owns its slug), held in `:persistent_term` so `RouterDispatch` can
  tell a request for a group from any other host request without a query.
  A slug in the set still goes to `Groups.fetch_group/1`; a slug outside it
  is answered here, which is what every non-publishing request is.

  The set is a negative filter, so the one thing it must never do is miss a
  group that exists. Three things keep it current:

    * every group write in `DBStorage` (create, update, delete) calls
      `erase/0`, which bumps a generation counter (an `:atomics` cell, no
      `:persistent_term` write); a set built under an older generation is
      not used, so a rebuild that read the database before a write and
      stored after it is ignored on the next read;
    * `ListingCache.CacheSync` erases on every `publishing:groups`
      broadcast, which reaches every node of a cluster, this one included.
      `Groups` broadcasts after its transaction commits, so this also
      covers a rebuild that ran between the `DBStorage` erase and the
      commit and could not see the new row yet;
    * a set older than five minutes is rebuilt, which bounds the staleness
      left by a missed broadcast or a group written outside this module.

  The counter is created by `CacheSync` at boot (`init/0`). Without it (the
  module's children not started, as in this module's own test suite) there
  is no set and every lookup answers `:unknown`, meaning "ask the
  database", the behaviour before the cache existed.
  """

  alias PhoenixKit.Modules.Publishing.DBStorage

  @counter_key {__MODULE__, :generation}
  @set_key {__MODULE__, :set}
  @max_age_ms 5 * 60_000

  @doc "Creates the generation counter once per node. Idempotent."
  @spec init() :: :ok
  def init do
    if :persistent_term.get(@counter_key, nil) == nil do
      :persistent_term.put(@counter_key, :atomics.new(1, signed: false))
    end

    :ok
  end

  @doc "Marks the set out of date. Cheap: one atomic add."
  @spec erase() :: :ok
  def erase do
    case :persistent_term.get(@counter_key, nil) do
      nil -> :ok
      ref -> :atomics.add(ref, 1, 1)
    end
  end

  @doc """
  Whether `slug` is a group's slug: `true`, `false`, or `:unknown` when there
  is no set to ask (no counter, or the database could not be read).
  """
  @spec member?(String.t()) :: boolean() | :unknown
  def member?(slug) when is_binary(slug) do
    case current_set() do
      nil -> :unknown
      set -> Map.has_key?(set, slug)
    end
  end

  defp current_set do
    case :persistent_term.get(@counter_key, nil) do
      nil -> nil
      ref -> fresh_set(:atomics.get(ref, 1))
    end
  end

  defp fresh_set(generation) do
    now = System.monotonic_time(:millisecond)

    case :persistent_term.get(@set_key, nil) do
      {^generation, set, built_at} when now - built_at < @max_age_ms -> set
      _ -> build(generation, now)
    end
  end

  # Stored under the generation read BEFORE the query: a write during the
  # query bumps the counter, so this set is already out of date when read.
  defp build(generation, now) do
    set = Map.new(DBStorage.all_group_slugs(), &{&1, true})
    :persistent_term.put(@set_key, {generation, set, now})
    set
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end
end
