defmodule PhoenixKit.Modules.Publishing.Web.Controller.PostFetching do
  @moduledoc """
  Post fetching functionality for the publishing controller.

  Handles fetching posts from cache and database, including:
  - Slug mode posts (versioned)
  - Timestamp mode posts
  - Language fallback logic
  """

  require Logger

  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.DBStorage
  alias PhoenixKit.Modules.Publishing.ListingCache

  # ============================================================================
  # Main Fetch Functions
  # ============================================================================

  @doc """
  Fetches a slug-mode post - iterates from highest version down, returns first published.
  Falls back to primary language or first available if requested language isn't found.
  """
  def fetch_post(group_slug, {:slug, post_slug}, language) do
    Publishing.read_post(group_slug, post_slug, language)
  end

  def fetch_post(group_slug, {:timestamp, date, time}, language) do
    identifier = "#{date}/#{time}"
    Publishing.read_post(group_slug, identifier, language)
  end

  # ============================================================================
  # Cache-Based Listing
  # ============================================================================

  @doc """
  Lists a group's posts from the listing cache when available, falling back to a direct DB read.

  Tries ListingCache (persistent_term) first for sub-microsecond reads.
  On cache miss, regenerates from the database.
  """
  def list_posts_with_cache(group_slug) do
    list_posts_with_listing_cache(group_slug)
  end

  defp list_posts_with_listing_cache(group_slug) do
    start_time = System.monotonic_time(:microsecond)

    case ListingCache.read(group_slug) do
      {:ok, posts} ->
        elapsed_us = System.monotonic_time(:microsecond) - start_time

        Logger.debug(
          "[PublishingController] Cache HIT for #{group_slug} (#{elapsed_us}μs, #{length(posts)} posts)"
        )

        posts

      {:error, :cache_miss} ->
        handle_cache_miss(group_slug, start_time)
    end
  end

  defp handle_cache_miss(group_slug, start_time) do
    Logger.warning(
      "[PublishingController] Cache MISS for #{group_slug} - regenerating cache synchronously"
    )

    # `broadcast: false`: a cache MISS means this node's copy was cold, not that
    # the data changed, so repopulating it must not announce `:cache_changed`
    # (which would make listing views invalidate the term we just rebuilt and
    # thrash the cache). Only mutation sites announce.
    case ListingCache.regenerate_if_not_in_progress(group_slug, broadcast: false) do
      :ok ->
        elapsed_ms = Float.round((System.monotonic_time(:microsecond) - start_time) / 1000, 1)

        Logger.info(
          "[PublishingController] Cache regenerated for #{group_slug} (#{elapsed_ms}ms)"
        )

        read_after_regeneration(group_slug)

      :already_in_progress ->
        elapsed_ms = Float.round((System.monotonic_time(:microsecond) - start_time) / 1000, 1)

        Logger.info(
          "[PublishingController] Cache regeneration in progress for #{group_slug}, using direct DB read (#{elapsed_ms}ms)"
        )

        # Use the SAME source the cache is built from (active/published version,
        # listing shape) rather than list_posts/2, which surfaces the LATEST
        # (possibly draft) version. Otherwise a concurrent loser of a cold
        # regeneration would briefly serve draft content — or drop a published
        # post whose latest version is an unpublished draft — on the public listing.
        DBStorage.list_posts_for_listing(group_slug)

      {:error, reason} ->
        Logger.error(
          "[PublishingController] Cache regeneration failed for #{group_slug}: #{inspect(reason)}"
        )

        DBStorage.list_posts_for_listing(group_slug)
    end
  end

  defp read_after_regeneration(group_slug) do
    case ListingCache.read(group_slug) do
      {:ok, posts} ->
        posts

      {:error, reason} ->
        Logger.warning(
          "[PublishingController] Cache read failed after regeneration for #{group_slug}: #{inspect(reason)}"
        )

        DBStorage.list_posts_for_listing(group_slug)
    end
  end
end
